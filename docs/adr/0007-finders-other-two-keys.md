# 7. Finder's other two keys, and a probe that had to start failing the other way

Date: 2026-08-10
Status: accepted

## Context

ADR 6 rewrote ⌘X and ⌘V in Finder. Two more keys on the same keyboard are wrong
in the same way, and the shelf's rule (small, local, reversible, obviously right
once you see it) covers both:

- **⌫ does nothing.** Not "does something surprising": nothing. Read off Finder's
  live menu bar, every menu, ⌫ carries no binding at all, while ⌘⌫ carries "Move
  to Trash" and ⌥⌘⌫ carries "Delete Immediately…". The capability is there and
  the key everybody's hands reach for is inert, which is the exact shape ADR 6
  described.
- **⏎ renames.** That is a real choice rather than an omission, and it is the
  one thing on this shelf where Apple is not obviously wrong. It is still the
  opposite of every other file manager, and the thing it displaces (opening) has
  no key of its own that anybody reaches for either.

The interesting part is not the rewrite, which is the same trick as before. It
is that ⌫ **destroys something** and ⌘X does not, so the safety argument ADR 6
made cannot simply be inherited.

## Decision

Three more rewrites, on the tap that already exists:

    ⌫   →  ⌘⌫    move the selection to the Trash
    ⏎   →  ⌘O    open the selection
    ⌘⏎  →  ⏎     rename, which is where ⏎ used to be

Verified against a real Finder on macOS 26 before any of it was written into the
app, each with a scratch folder and no user data involved:

| rewrite | result |
|---|---|
| ⌫ with Command inserted, nobody holding Command | file left the folder, arrived in the Trash |
| ⏎ with the key code changed to O and Command inserted | front window navigated into the selected folder |
| ⌘⏎ with Command removed | the rename field opened, focused role `AXTextField` on 20 of 20 samples |

**⌘⏎ was free.** Checked the same way as everything else, by reading Finder's
whole menu bar: nothing is bound to ⌘⏎, or to ⏎, or to ⌫. Renaming moves onto an
unused key rather than over somebody else's.

**Taurine still moves and deletes nothing.** ⌫ does not put a file in the Trash;
Finder does, because what Finder receives is the ⌘⌫ it has always answered. The
Trash, the "are you sure" for a locked file, the authentication prompt, and ⌘Z
all come free and correct. A bug here cannot lose data, because the data is never
in Taurine's hands. And the Trash is itself a second net: the worst outcome of a
rule firing when it should not is a file one keystroke away from coming back.

### The focus probe had to grow a third answer

ADR 6 asked Finder one question before rewriting anything: is a text field
focused? It had two answers, and an unanswerable question counted as "no", so
the rewrite went ahead. That was argued for at the time and the argument still
holds **for the cut**: a probe failure there costs a copy instead of a cut, which
is visible, harmless and undone with ⌘Z, whereas a fix that quietly stops working
whenever a probe fails is one nobody can report a bug about.

The same failure on ⌫ would trash the file being renamed. So the probe now
returns one of three things, and the two halves of the shelf read it opposite
ways:

| | `.text` | `.fileList` | `.unknown` |
|---|---|---|---|
| ⌘X ⌘C ⌘V | pass through | rewrite | **rewrite** |
| ⌫ ⏎ ⌘⏎ | pass through | rewrite | **pass through** |

`.fileList` is a positive statement, not the absence of a negative. It is built
from what Finder was measured to report in every place a person can be standing:

| where | role | identifier | parent |
|---|---|---|---|
| list view | `AXOutline` | `ListView` | `AXScrollArea` |
| icon view | `AXList` | `IconView` | `AXScrollArea` |
| column view | `AXList` | none at all | `AXScrollArea` |
| gallery view | `AXList` | `GalleryView` | `AXScrollArea` |
| the desktop | `AXGroup` | | `AXScrollArea` |
| rename field | `AXTextField` | | `AXApplication` |
| search field | `AXTextField` | | `AXGroup` |
| Go to Folder | `AXTextField` | | `AXSheet` |
| Get Info | `AXWindow` | | `AXApplication` |
| a name-clash sheet | **no answer at all** | | |

That last row is the one worth having gone looking for. While Finder has a modal
sheet up, this question is not answered, so a rule that treated silence as
permission would be rewriting keys into a dialog. Failing closed turns the
scariest case into the quietest one: during a sheet, ⌫ and ⏎ are exactly the keys
they have always been, and ⏎ goes on pressing the default button.

**The identifier is checked for outlines and only for outlines, and that is the
sidebar's fault.** The sidebar is an `AXOutline` inside an `AXScrollArea` too, so
nothing about its shape separates it from the list view. `AXDescription` looked
like the way out, since it reads "sidebar" and "list view", until it was measured
in a Finder forced into German, where the same two elements read "Seitenleiste"
and "Listendarstellung". It is localized, so a rule built on it would work here
and quietly stop working abroad. `AXIdentifier` is not: the same German Finder
still says `ListView` and `_NS:8`.

If a future macOS renames that identifier, list view stops being recognised and ⌫
goes back to doing nothing there. That is the direction this whole design
prefers.

### One tap, three switches

The three fixes watch the same application, need the same permission and ask
Finder the same question, so a second tap would mean a second thread, a second
Accessibility round trip per keystroke and a second thing to take down at exactly
the right moment. Which fixes are on travels into the callback as a scalar in the
cell the tap thread already reads, so switching one on in the menu does not
rebuild anything and does not disturb a pending cut.

A fix that is off costs nothing: it is the first comparison in the callback's
filter, before the key is even read.

### Cost per keystroke

The probe is four Accessibility round trips rather than two, and it now runs for
seven keys rather than four. Measured on this Mac, warm, from a background
thread: **92 µs** for an answer that stops at the role, **133 µs** for one that
walks to the parent as well. The messaging timeout stays at 50 ms, which is far
beyond a healthy answer and far inside the timeout that makes macOS switch a tap
off. Every other key on the keyboard is still decided by integer comparisons and
never reaches any of this.

## What this gets wrong

- **The sidebar.** A sidebar row is a file list as far as this rule can tell, and
  ⌘⌫ there removes a favourite rather than moving a file. Today plain ⌫ does
  nothing there, so this is a real change. It is not data loss (the folder is
  untouched, and it can be dragged back), and it is exactly what ⌘⌫ has always
  done in that spot, but it is a surprise and it is written down rather than
  guessed at.
- **⏎ opening is a matter of taste, and it takes rename with it.** Somebody with
  thirty years of ⏎-renames in their hands will hate this, which is why it is a
  separate switch from the other two and why rename lands on a key Finder was not
  using rather than disappearing.
- **A ⌫ pressed while Finder is busy does nothing.** If the probe cannot be
  answered the key passes through, so under a wedged Finder the fix appears to
  switch itself off. That is the failure this is arranged to prefer, and unlike
  the cut fix it is silent rather than visible.
- **Only Finder,** and only the four views and the desktop that were measured. A
  surface Finder grows later reports something this rule has not been told about,
  and there ⌫ will do nothing until somebody measures it.
- **The tap follows activation, so it lags it slightly.** Unchanged from ADR 6,
  and for these keys the lagging direction is the harmless one: a ⌫ arriving
  after another application came forward but before its notification reaches us
  is a ⌫ in a Finder that is no longer frontmost, and Finder is not the one
  receiving it.

## Consequences

- `FinderCutPolicy` became `FinderKeyPolicy` and `FinderCutPaste` became
  `FinderFixes`, because both were named after one of the three things they now
  do. The preference key for the cut fix is deliberately unchanged, so a choice
  made in 1.3 survives the rename, and a test asserts that.
- `FinderFocus` no longer answers a yes/no question, and the two readings of
  `.unknown` are the only place in Taurine where two features deliberately treat
  the same uncertainty in opposite directions. Both are argued for in the file.
- The menu shelf has five entries rather than two, all but one of them sharing a
  single "Grant Accessibility permission…" item.
- The badge still reads `0 timers`. Nothing here polls, including the
  Accessibility connection, which is only consulted in response to a keystroke.
