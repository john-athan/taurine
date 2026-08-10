# 6. ⌘X in Finder means cut, by rewriting two keys rather than moving any files

Date: 2026-08-10
Status: accepted

## Context

⌘X does nothing in Finder, and never has. The move exists: copy a file, then
hold Option and the Edit menu's Paste turns into "Move Item Here", ⌥⌘V. So the
capability has shipped for years behind a keystroke almost nobody finds, while
the keystroke everybody's hands already know is inert.

Apple's argument for that is about the *implementation* of cut, not about the
keystroke. A cut that marks files and then never gets pasted has to mean
something, and the usual answer is a limbo where files look half deleted. That
argument does not apply to a cut that copies immediately and moves only on
paste, which is what Finder's own ⌥⌘V already is.

This is the second entry in the category ADR 4 opened: things the system should
have got right, where the fix is small, local and reversible. It is also the
first one that needs a keyboard tap, which is a much bigger thing to ask for
than a scroll tap, and most of what follows is about containing that.

## Decision

Taurine rewrites two keystrokes in Finder, and does nothing else:

    ⌘X  →  ⌘C     copy, and remember that a cut is pending
    ⌘V  →  ⌥⌘V    Move Item Here, if that cut is still the pasteboard

**Taurine moves no files.** Not one line of this feature opens, copies, renames
or deletes anything. Finder does the move, from Finder's point of view nothing
unusual has happened, and everything that comes with a Finder move comes free
and correct: the progress sheet, the name-clash dialog, the authentication
prompt for a folder you do not own, and Undo. A bug here cannot lose data,
because the data is never in Taurine's hands.

**The rewrite is done in place**, in the same style as the scroll fix. No event
is swallowed and none is synthesised, so there is no synthetic keystroke to feed
back into our own tap and no unmatched key-up left in an application's queue.
Key-down and key-up are rewritten alike, so what Finder sees is a balanced ⌘C
press even though ⌘X was typed.

**Only the key code is rewritten**, and that is a measured constraint rather
than minimalism. Writing the event's Unicode string as well looks like the more
thorough rewrite, and it is what this was first written as. Measured against a
real Finder on macOS 26, with one dummy file and the pasteboard's change count
as the verdict, three runs each:

| rewrite | Finder copies? |
|---|---|
| plain ⌘C, untouched (control) | yes, 3 of 3 |
| ⌘X, key code only | yes, 3 of 3 |
| ⌘X, Unicode string only | no, 0 of 3 |
| ⌘X, both, key code first | no, 0 of 3 |
| ⌘X, both, string first | no, 0 of 3 |

Setting the string stops Finder matching the Edit menu's equivalent at all, and
the keystroke simply does nothing, which is the worst shape a bug can have: it
looks like the feature is switched off. Nothing is lost by leaving the string
alone. It goes on saying "x", and AppKit pays it no attention;
`charactersIgnoringModifiers`, which is what a menu equivalent is matched
against, is derived from the key code and reads "c" as soon as the key code
does.

**The Option flag on the paste is synthetic and Finder does not care.** Verified
the same way: a ⌥⌘V posted with nobody holding Option moves the file.

### The tap exists only while Finder is frontmost

A keyboard tap that is always armed sees every keystroke on the machine.
Taurine has no business seeing those, and "we promise not to look" is not the
kind of claim this app makes about anything else. So the tap is created when
Finder comes forward and taken down, thread joined, when anything else does.
Outside Finder there is no tap, no thread and no callback: not a policy, an
absence.

That rides on the workspace activation notification, which was already being
observed for the scroll fix, so it adds no timer and nothing polls. While the
tap is up it reads exactly one field per event, the key code, and for every key
but four that is the whole of it. Nothing is logged, stored or counted, and
Taurine opens no socket to send it anywhere.

### Renaming a file is left alone

In a text field ⌘X really is cut, and Finder does it correctly. Before rewriting
anything, Taurine asks Finder what it has focused and passes the keystroke
straight through if it is a text field, a text area or a combo box, which covers
renaming, the search field and Get Info's comments box. That is an Accessibility
question with a 50 ms messaging timeout, asked only for ⌘X, ⌘C and ⌘V, and
measured here at 38 µs.

It fails open: a question that cannot be answered is treated as "not text" and
the rewrite goes ahead. The other way round, a feature that quietly stops
working whenever a probe fails is one nobody can file a bug about; this way
round the failure is ⌘X copying instead of cutting inside a rename box, which is
visible, harmless and undone with ⌘Z.

### Remembering a cut without trusting a memory

The dangerous part of a cut is the gap before the paste. If Taurine remembers a
cut that the pasteboard no longer holds, ⌘V moves the wrong files. So what is
remembered is not "the user pressed ⌘X" but the pasteboard's change count,
sampled just before the cut copies and again once it has, which pins the exact
pasteboard that cut produced. At paste time the count is read once more, and the
cut is live only if it matches. Anything copying anything, anywhere, ends it.
The sample costs 0.9 µs and is taken only for those four keys.

Three rules close the ways that could still go wrong, each of them measured
against a real Finder:

- **A ⌘C typed in Finder forgets the cut**, and does so without asking whether
  the cut currently looks pending. At that instant Finder has not handled the
  ⌘C yet, so the pasteboard is still the cut's and every "is a cut pending" test
  says yes. A rule that consulted it would keep the cut and the next ⌘V would
  move the files that copy was about to produce. Verified: ⌘X on a.txt, ⌘C on
  b.txt, ⌘V in another folder copies b.txt and leaves a.txt where it was.
- **A ⌘X that copied nothing is not a cut.** With no copy the change count never
  moves, and ⌘V stays an ordinary paste. Trying to stage that turned up
  something worth knowing: in Finder there is no such thing as copying nothing.
  Press ⌘C in a window with no item selected and Finder copies the window's own
  folder, change count and all. So a ⌘X with nothing selected cuts the folder
  you are looking at, and pasting moves that folder, which is precisely what
  ⌘C followed by ⌥⌘V does without Taurine. Verified with a stale copy of another
  file sitting on the pasteboard first, the shape where getting it wrong would
  move somebody else's file: the folder moved, the stale file was untouched.
  The rule stays, because a Finder too busy to copy produces the same state.
- **A paste that moved nothing ends the claim**, and an application switch
  settles any claim still waiting for its copy. Without those two, a ⌘X that
  copied nothing would leave a claim outstanding indefinitely.

A paste that *did* move something, on the other hand, leaves the cut exactly
where it was. That is a correction, and it came from a user inside a minute of
using it: move a file, press ⌘Z to undo the move, press ⌘V again, and the second
paste was an ordinary one, so the file was copied and ended up in both folders.
The rule now is that a cut lasts as long as the pasteboard it pinned, and
measurement says that is the honest span. Across a move and an undo the change
count holds still and the file URL on the pasteboard follows the file to its new
home and back. So ⌘V goes on meaning Move Item Here for as long as ⌥⌘V would,
which is the same answer Finder gives, arrived at without a special case.

The pinning itself is done at every reading of the pasteboard, not only on the
key-up of the cut, and that is not a refinement either. Measured against a real
Finder, the key-up sample was too early every single time: the copy lands after
the key comes back up. Pinning only there meant the loose claim was the path
every decision actually took, while the exact rule sat unused.

## What this gets wrong

- **Plain Dvorak, and any layout where the key position and the character
  disagree.** The rule fires only when the key code *and* the character both say
  x, which they do on QWERTY, QWERTZ, AZERTY, Colemak and "Dvorak - Qwerty ⌘".
  Where they disagree the feature does nothing at all, which is the intended
  failure: rewriting a key code under a layout that maps it elsewhere would send
  Finder a keystroke nobody pressed.
- **One window remains where a cut can be mistaken.** While a cut is waiting for
  its copy to land, a background process writing files to the pasteboard could
  be taken for Finder's copy. It needs a Finder too busy to copy for the length
  of a keypress, or a ⌘X with nothing selected, plus another process writing
  files to the pasteboard, plus no paste and no application switch in between,
  since either settles the claim. It is narrow, it is not zero, and it is the
  price of not polling the pasteboard.
- **A ⌘V that arrives before Finder has copied is a paste, not a move.** The cut
  is only live once its copy exists, so pressing ⌘V while Finder is still busy
  with the ⌘X gives you a copy. That is the safe direction, and it is not
  theoretical: it is reproducible by driving Finder with AppleEvents fast enough
  that the copy has not landed a second later. At human speed it has not been
  seen.
- **The tap follows activation, so it lags it slightly.** A ⌘X typed in the few
  milliseconds between another application coming forward and its notification
  arriving would be rewritten by a tap that should already be gone. The reverse,
  a keystroke in Finder just before the tap is armed, is the harmless direction:
  ⌘X does what it always did, nothing.
- **Only Finder.** Path Finder, ForkLift and the rest have their own cut, and
  the rule is keyed to Finder's bundle identifier.
- **No dimmed icons.** Windows greys out cut files to show a move is pending.
  Nothing here draws on Finder's windows, so a pending cut is invisible until
  you paste. Recording it in the menu was considered and dropped: a badge that
  is right only while Taurine's menu is open is worse than none.

## Consequences

- The event tap machinery is now shared. The thread, the port, the re-arming and
  the teardown, all of which were arrived at by measurement in ADR 4, live in
  one `EventTap` and both fixes hand it a cell and a C callback. The scroll
  fix's hot path pays two comparisons and one indirect call for that. Its
  teardown ordering, the part that was expensive to get right, is now written
  once instead of copied.
- Accessibility has a second consumer, so `ScrollPermission` became
  `AccessibilityPermission` and the menu has one "Grant Accessibility
  permission…" item, shown when either fix is waiting on it.
- Off by default, like the scroll fix, and for a stronger reason: it needs a
  permission and it rewires two keys people have been pressing for thirty years.
- A tap is created and joined on every application switch while the feature is
  on. That is a thread start and a run loop teardown at human pace, not at event
  pace, and `stop()` still does not return until the tap thread is gone.
- The badge still reads `0 timers`. Nothing here polls, including the pasteboard,
  which is read only in response to a keystroke.
- Taurine is now an application that can, in principle, see keystrokes. The
  containment is structural (no Finder, no tap) and the tests assert it as a
  fact about which threads exist rather than as a claim in a README.
