# 8. One shortcut for pasting plain text, written as a preference rather than tapped

Date: 2026-08-10
Status: accepted

## Context

Pasting without carrying the formatting along is something every application
that can paste rich text offers. It is just not on the same key twice. Read off
the live menu bars of what happened to be running here:

| application | pastes as plain text on |
|---|---|
| Chrome | ⇧⌘V (and ⌥⇧⌘V, which it also carries) |
| VS Code, Slack, Firefox | ⇧⌘V |
| TextEdit, Pages, Keynote, Mail, Notes, Safari | ⌥⇧⌘V |

So whether the shortcut your hands know works depends on which window is in
front. Somebody who lives in a browser never notices; somebody who moves between
a browser and Mail hits it several times a day.

The obvious way to fix this, given ADR 6 and ADR 7 already exist, is another
rewrite in an event tap: turn ⇧⌘V into ⌥⇧⌘V. That would be a **system-wide**
tap, and it directly contradicts what ADR 6 promises. The containment argument
there is not "we only look at four keys", it is "outside Finder there is no tap,
no thread and no callback: not a policy, an absence". A tap armed everywhere,
always, to catch one keystroke, would trade that away for a convenience.

## Decision

Do not tap anything. macOS already has the mechanism.

A menu item's key equivalent can be overridden by title, for one application or
for all of them, and the override lives in one dictionary:
`NSUserKeyEquivalents` in the preferences domain that applies to any
application. That is precisely where System Settings writes when you add an App
Shortcut under Keyboard ▸ Keyboard Shortcuts. Taurine writes the same entries:

    "Paste and Match Style"        →  "@$v"
    "Einsetzen und Stil anpassen"  →  "@$v"

(`@` is Command, `$` is Shift. It is what System Settings writes for the same
choice.)

Measured before it was written into the app: with that entry present, a restarted
TextEdit reports its "Paste and Match Style" item at ⇧⌘V rather than ⌥⇧⌘V, read
back off the live menu bar through Accessibility rather than taken on trust.

**Both languages, because the match is on the title an application shows.** A
TextEdit forced into German calls the item "Einsetzen und Stil anpassen" and went
on showing ⌥⇧⌘V while only the English entry was written. An application in one
language on a system in another is ordinary, so both go in. A title no
application has is not a risk, it is a line that never matches.

**Only two titles, and both were read off a real menu.** The risk runs the other
way: a title used by an item that is *not* a plain paste would move that item
onto ⇧⌘V. The list stays short and stays measured rather than being padded with
plausible-sounding variants.

**Existing entries are merged, never replaced.** This dictionary is shared with
System Settings, so anything in it that Taurine did not write is a choice
somebody made. A title somebody has already bound by hand keeps their binding and
the menu says so. Switching the fix off removes only entries whose value is the
one we write, and removes the key entirely rather than leaving an empty
dictionary behind, so the domain ends up as it was found.

**There is no separate "on" flag.** The dictionary is the state. Switching this
on in System Settings and switching it on in Taurine are the same act, and the
menu cannot claim to be on while the preference says otherwise.

### What choosing the preference over a tap buys

- No permission. Nothing to grant, and nothing to grant *again* after an update,
  which is the standing annoyance of the other two fixes.
- No tap, no thread, no callback, no cost at all when you press the key.
- It cannot be wrong about what you are doing, because it never looks. The menu
  either has an item by that name or it does not.
- Reversing it is deleting a dictionary entry.

### What it costs

- **Applications pick it up when they next start.** The menu is built at launch,
  so anything already running keeps the old shortcut until it is quit and
  reopened. The menu item says so at the moment it is switched on, because
  otherwise it looks like nothing happened.
- **Only real menus.** An application that draws its own menu bar, or that
  handles ⇧⌘V without a menu item, is untouched. In practice those are the ones
  that already do the right thing.
- **Only these titles.** An application that calls it something else keeps
  whatever it had.

## What this gets wrong

- **An application that already uses ⇧⌘V for something else and also has a
  "Paste and Match Style" item** ends up with two menu items claiming one
  shortcut, and AppKit picks one. Surveyed across what was running: Ghostty binds
  ⇧⌘V to "Paste Selection" but has no item by our title, so it is untouched, and
  nothing else came close. It is possible rather than observed.
- **Nothing detects the collision for you.** Taurine writes the entry and does
  not go reading every application's menus to check, because that would mean
  launching them.
- **It is a shared preference.** Something else that rewrites the whole
  `NSUserKeyEquivalents` dictionary rather than merging into it would drop our
  entries, and the menu would honestly report itself off afterwards.

## Consequences

- The shelf now has an entry that needs no permission and arms nothing, which is
  worth having as a reminder that "rewrite the event" is not the only tool on it.
  Where a system preference already exists, using it beats tapping the keyboard.
- The rule is written as functions over a dictionary, with the preferences domain
  behind a two-method protocol, so the whole of the merge-and-prune behaviour is
  tested against a dictionary in memory. A test run leaves no trace in a domain
  that holds a large part of how the Mac is set up.
- `Sources/Paste/` is a new subsystem folder with one file in it, because this
  belongs to neither the Finder shelf nor the scroll fix.
