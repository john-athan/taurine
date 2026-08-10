import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// The Finder shelf: the rules, the rewrites, and the memory of a cut.
///
/// Almost all of this needs no permission, no Finder and no hardware, because
/// the three decisions are pure: what does this keystroke mean, what does that
/// do to the event, and what does it do to the pending cut. The rewrites are
/// checked against real `CGEvent`s, built and read straight back, so "⌘X becomes
/// ⌘C" is asserted about the fields an application actually reads rather than
/// about our own opinion of them.
///
/// What is not asserted here, and cannot be: that Finder answers ⌥⌘V with Move
/// Item Here, ⌘⌫ with the Trash and ⌘O with an open document. That is Finder's
/// behaviour, it is decades old, and testing it would mean moving somebody's
/// files. See ADR 6 and ADR 7 for how each was verified instead.
///
/// The last suites drive a real `FinderFixes` and, if the test binary inherited
/// Accessibility permission from the terminal that ran it, a real keyboard tap
/// for the microseconds it takes to assert and take it down again. They assert
/// the honest answer either way, so the run passes with the permission and
/// without it.
func runFinderKeyTests() {

    // MARK: - the rule

    Check.suite("rule: the cut is rewritten going down and coming back up") {
        // Both halves, so what Finder sees is a balanced ⌘C press rather than a
        // ⌘C that is never released and an X that was never pressed.
        Check.equal(decide(press("x", kVK_ANSI_X, down: true)), .copyInstead, "⌘X down")
        Check.equal(decide(press("x", kVK_ANSI_X, down: false)), .copyInstead, "⌘X up")
    }

    Check.suite("rule: Command alone, and only three keys") {
        Check.equal(decide(press("x", kVK_ANSI_X, chord: Chord(command: true, shift: true))),
                    .passThrough, "⇧⌘X belongs to somebody else")
        Check.equal(decide(press("x", kVK_ANSI_X, chord: Chord(command: true, control: true))),
                    .passThrough, "⌃⌘X likewise")
        Check.equal(decide(press("x", kVK_ANSI_X, chord: Chord(command: true, option: true))),
                    .passThrough, "⌥⌘X likewise")
        Check.equal(decide(press("x", kVK_ANSI_X, chord: .bare)),
                    .passThrough, "a bare x is somebody typing")
        Check.equal(decide(press("z", kVK_ANSI_Z)), .passThrough, "⌘Z is Finder's own undo")
    }

    Check.suite("rule: paste moves only while the cut is still on the pasteboard") {
        Check.equal(decide(press("v", kVK_ANSI_V), pending: true), .moveInstead,
                    "⌘V with a live cut")
        // An ordinary paste, and it clears the ledger on its way through. A ⌘X
        // that copied nothing leaves a claim outstanding, and a claim nobody
        // ever closes is one that a later copy somewhere else could be handed.
        Check.equal(decide(press("v", kVK_ANSI_V), pending: false), .forgetTheCut,
                    "⌘V with no live cut pastes, and ends whatever claim there was")
        Check.equal(decide(press("v", kVK_ANSI_V, down: false), pending: true), .passThrough,
                    "the key-up is not a second paste")
    }

    Check.suite("rule: a copy forgets the cut before its own pasteboard exists") {
        // The ordering trap, and the reason this rule ignores `pending`. At the
        // moment ⌘C is seen, Finder has not handled it, so the pasteboard is
        // still the cut's and every test for "is a cut pending" says yes. A rule
        // that consulted it would keep the cut, and the next ⌘V would move the
        // files this copy is about to put on the pasteboard.
        Check.equal(decide(press("c", kVK_ANSI_C), pending: true), .forgetTheCut,
                    "⌘C while a cut is pending")
        Check.equal(decide(press("c", kVK_ANSI_C), pending: false), .forgetTheCut,
                    "and while one only looks pending")
    }

    Check.suite("rule: the two other ways to change your mind") {
        Check.equal(decide(press("v", kVK_ANSI_V, chord: .commandOption), pending: true),
                    .forgetTheCut, "somebody who used ⌥⌘V has done the move themselves")
        Check.equal(decide(press(nil, kVK_Escape, chord: .bare), pending: true),
                    .forgetTheCut, "Escape means never mind")
        Check.equal(decide(press(nil, kVK_Escape)), .passThrough,
                    "⌘Escape is not that gesture")
    }

    Check.suite("rule: renaming a file is left completely alone") {
        // The case that decides whether any of this is welcome. In a text field
        // ⌘X really is cut and ⌫ really deletes a character, and Finder already
        // does both correctly.
        for (character, code) in [("x", kVK_ANSI_X), ("c", kVK_ANSI_C), ("v", kVK_ANSI_V)] {
            Check.equal(decide(press(character, code), surface: .text, pending: true), .passThrough,
                        "⌘\(character.uppercased()) in a text field")
        }
        Check.equal(decide(press(nil, kVK_Delete, chord: .bare), surface: .text), .passThrough,
                    "⌫ in a text field deletes a character, as it always did")
        Check.equal(decide(press(nil, kVK_Return, chord: .bare), surface: .text), .passThrough,
                    "↩ in a text field commits the new name")
    }

    Check.suite("rule: a layout where the key and the character disagree does nothing") {
        // Plain Dvorak: the key at X's position produces "q". Rewriting it to
        // the key at C's position would send Finder a keystroke nobody pressed,
        // so the rule declines to fire and the feature is simply absent.
        Check.equal(decide(press("q", kVK_ANSI_X)), .passThrough, "key code without the character")
        Check.equal(decide(press(nil, kVK_ANSI_X)), .passThrough, "an event carrying no character")
        Check.equal(decide(press("x", kVK_ANSI_Q)), .passThrough, "character without the key code")
    }

    // MARK: - the rewrite, on real events

    Check.suite("rewrite: ⌘X becomes ⌘C, by key code and by nothing else") {
        // The key code is the whole rewrite, and that is a measured constraint
        // rather than minimalism: writing the event's Unicode string as well
        // stops Finder from matching the menu equivalent at all. See the note in
        // `FinderKeyPolicy.apply`.
        //
        // These two checks are the reason it is not needed. The event goes on
        // carrying the string it was born with, and AppKit pays it no attention:
        // `charactersIgnoringModifiers`, which is what a menu equivalent is
        // matched against, is derived from the key code and comes out as "c".
        let e = event(kVK_ANSI_X, down: true, flags: .maskCommand)
        Check.equal(KeyPress.read(e).character, "x", "the event under test really carries an x")
        FinderKeyPolicy.apply(.copyInstead, to: e)
        Check.equal(e.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_C),
                    "the key code is C's")
        Check.equal(e.flags.rawValue, CGEventFlags.maskCommand.rawValue,
                    "the modifiers are untouched, so this is still a Command press")
        Check.equal(KeyPress.read(e).character, "x",
                    "the stored string is left alone, and stale, on purpose")
        if let cocoa = Check.unwrap(NSEvent(cgEvent: e), "the rewritten event is still an NSEvent") {
            Check.equal(cocoa.charactersIgnoringModifiers, "c",
                        "and what AppKit matches a menu key equivalent against says c")
        }
    }

    Check.suite("rewrite: ⌘V becomes ⌥⌘V and changes nothing else") {
        let e = event(kVK_ANSI_V, down: true, flags: .maskCommand)
        FinderKeyPolicy.apply(.moveInstead, to: e)
        Check.that(e.flags.contains(.maskAlternate), "Option is now set, though nobody held it")
        Check.that(e.flags.contains(.maskCommand), "and Command still is")
        Check.equal(e.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_V),
                    "the key itself is not touched")
        Check.equal(KeyPress.read(e).character, "v", "nor the character")
    }

    Check.suite("rewrite: the decisions that change nothing change nothing") {
        for action in [FinderKeyAction.passThrough, .forgetTheCut] {
            let e = event(kVK_ANSI_X, down: true, flags: [.maskCommand, .maskShift])
            FinderKeyPolicy.apply(action, to: e)
            Check.equal(e.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_X),
                        "\(action): the key code survives")
            Check.equal(e.flags.rawValue, CGEventFlags([.maskCommand, .maskShift]).rawValue,
                        "\(action): the modifiers survive")
            Check.equal(KeyPress.read(e).character, "x", "\(action): the character survives")
        }
    }

    Check.suite("read: a live event comes back as the keystroke that was typed") {
        let down = KeyPress.read(event(kVK_ANSI_X, down: true, flags: .maskCommand))
        Check.equal(down.keyCode, Int64(kVK_ANSI_X), "the key")
        Check.equal(down.character, "x", "the character, with Command held")
        Check.that(down.isDown, "a key-down")
        Check.equal(down.chord, .command, "Command and nothing else")

        let up = KeyPress.read(event(kVK_ANSI_X, down: false, flags: .maskCommand))
        Check.that(!up.isDown, "a key-up")
    }

    Check.suite("read: the modifiers nobody chose are ignored") {
        // Caps Lock and Fn ride along on ordinary keystrokes, and Fn is set on
        // every key of some keyboards. A rule written against raw flag equality
        // would silently stop working for those people.
        let e = event(kVK_ANSI_X, down: true,
                      flags: [.maskCommand, .maskAlphaShift, .maskSecondaryFn, .maskNumericPad])
        Check.equal(KeyPress.read(e).chord, .command, "still Command and nothing else")
        Check.equal(decide(KeyPress.read(e)), .copyInstead, "and the cut still fires")
    }

    // MARK: - the memory of a cut

    Check.suite("ledger: nothing is pending until something is") {
        Check.that(!FinderCutLedger.hasCut(.nothingPending), "a fresh ledger holds no cut")
        Check.that(!FinderCutLedger.isPending(.nothingPending, changeCount: 7),
                   "and nothing to check against the pasteboard")
    }

    Check.suite("ledger: a cut, and the copy that lands under it") {
        let down = FinderCutLedger.after(.copyInstead, isDown: true,
                                         cut: .nothingPending, changeCount: 10)
        Check.equal(down.before, 10, "the count the copy is about to move past")
        Check.that(down.awaitingCopy, "and we are waiting for it")

        let up = FinderCutLedger.after(.copyInstead, isDown: false, cut: down, changeCount: 11)
        Check.equal(up.pending, 11, "the key-up names the pasteboard this cut owns")
        Check.that(!up.awaitingCopy, "with nothing left to wait for")
        Check.that(FinderCutLedger.isPending(up, changeCount: 11), "⌘V now would move")
        Check.that(!FinderCutLedger.isPending(up, changeCount: 12),
                   "and one copy by anybody, anywhere, ends that")
    }

    Check.suite("ledger: a cut with nothing selected is not a cut") {
        // Finder copies nothing, so the count never moves, and ⌘V has to stay an
        // ordinary paste. Getting this wrong would move the *previous* copy's
        // files, which is the worst thing this feature could do.
        let down = FinderCutLedger.after(.copyInstead, isDown: true,
                                         cut: .nothingPending, changeCount: 10)
        let up = FinderCutLedger.after(.copyInstead, isDown: false, cut: down, changeCount: 10)
        Check.that(!FinderCutLedger.isPending(up, changeCount: 10), "⌘V pastes, it does not move")
    }

    Check.suite("ledger: a Finder too busy to have copied yet") {
        // The key came back up before the copy landed. The cut stays claimable
        // until some copy does land, and `FinderKeyPolicy` is what stops that
        // claim from being handed a copy somebody else typed.
        let down = FinderCutLedger.after(.copyInstead, isDown: true,
                                         cut: .nothingPending, changeCount: 10)
        let up = FinderCutLedger.after(.copyInstead, isDown: false, cut: down, changeCount: 10)
        Check.that(up.awaitingCopy, "still waiting")
        Check.that(FinderCutLedger.isPending(up, changeCount: 11),
                   "the late copy is taken as ours")
    }

    Check.suite("ledger: a move does not spend the cut, because the pasteboard is unchanged") {
        // Found by a user in about a minute. Move a file, press ⌘Z to undo the
        // move, press ⌘V again: with the cut spent, the second paste was an
        // ordinary one and the file was copied into both folders. Nothing about
        // the pasteboard changes across a move or an undo (measured: the change
        // count holds still and the URL it carries follows the file), so nothing
        // about the cut may change either.
        let cut = PendingCut(before: 10, pending: 11, awaitingCopy: false)
        let after = FinderCutLedger.after(.moveInstead, isDown: true, cut: cut, changeCount: 11)
        Check.equal(after, cut, "the cut survives its own paste")
        Check.that(FinderCutLedger.isPending(after, changeCount: 11),
                   "so ⌘V after an undo moves again rather than copying")
    }

    Check.suite("ledger: changing your mind does spend it") {
        let cut = PendingCut(before: 10, pending: 11, awaitingCopy: false)
        let after = FinderCutLedger.after(.forgetTheCut, isDown: true, cut: cut, changeCount: 11)
        Check.equal(after, .nothingPending, "the ledger is emptied")
        Check.that(!FinderCutLedger.hasCut(after), "so the next ⌘V pastes rather than moves")
    }

    Check.suite("ledger: a waiting claim is pinned the first time it is looked at") {
        // The key-up sample was too early in every live measurement: Finder's
        // copy lands after the key comes back up. Without pinning at each
        // reading, the loose claim would be the path every decision took.
        let waiting = PendingCut(before: 10, pending: -1, awaitingCopy: true)
        let pinned = FinderCutLedger.pin(waiting, changeCount: 11)
        Check.equal(pinned, PendingCut(before: 10, pending: 11, awaitingCopy: false),
                    "the copy that landed is now the cut's own pasteboard, by number")
        Check.that(FinderCutLedger.isPending(pinned, changeCount: 11), "and it is live")
        Check.that(!FinderCutLedger.isPending(pinned, changeCount: 12),
                   "and nothing later can be taken for it")

        Check.equal(FinderCutLedger.pin(waiting, changeCount: 10), waiting,
                    "a count that has not moved is left waiting, not given up on")
        let settled = PendingCut(before: 10, pending: 11, awaitingCopy: false)
        Check.equal(FinderCutLedger.pin(settled, changeCount: 99), settled,
                    "and a cut that already knows its pasteboard is never re-pinned")
    }

    Check.suite("ledger: a second cut replaces the first") {
        let first = PendingCut(before: 10, pending: 11, awaitingCopy: false)
        let second = FinderCutLedger.after(.copyInstead, isDown: true, cut: first, changeCount: 11)
        Check.equal(second.pending, -1, "the old pasteboard is no longer claimed")
        Check.equal(second.before, 11, "and the new cut starts from where we are")
    }

    Check.suite("ledger: an unanswered claim does not survive leaving Finder") {
        // Switching applications is where "Finder may not have copied yet" stops
        // being a reasonable thing to believe. Either the copy landed, and the
        // cut is pinned to it exactly, or it never will and there was no cut.
        let waiting = PendingCut(before: 10, pending: -1, awaitingCopy: true)
        let landed = FinderCutLedger.resolve(waiting, changeCount: 11)
        Check.equal(landed, PendingCut(before: 10, pending: 11, awaitingCopy: false),
                    "a copy did land, so the cut now names one exact pasteboard")
        Check.equal(FinderCutLedger.resolve(waiting, changeCount: 10), .nothingPending,
                    "nothing was ever copied, so there was never a cut to carry")

        let settled = PendingCut(before: 10, pending: 11, awaitingCopy: false)
        Check.equal(FinderCutLedger.resolve(settled, changeCount: 40), settled,
                    "a cut that already knows its pasteboard is carried untouched")
        Check.equal(FinderCutLedger.resolve(.nothingPending, changeCount: 40), .nothingPending,
                    "and an empty ledger stays empty")
    }

    Check.suite("ledger: passing an event through leaves the ledger alone") {
        let cut = PendingCut(before: 10, pending: 11, awaitingCopy: false)
        Check.equal(FinderCutLedger.after(.passThrough, isDown: true, cut: cut, changeCount: 99),
                    cut, "a keystroke that means nothing to us means nothing to the cut")
    }

    // MARK: - the two other keys

    Check.suite("rule: ⌫ trashes, but only where Finder has a list of files") {
        // The whole of the difference between this key and the cut. ⌘X failing
        // open costs a copy; ⌫ failing open would cost a file, so it fires on a
        // positive answer and on nothing else.
        Check.equal(decide(press(nil, kVK_Delete, chord: .bare), surface: .fileList),
                    .trashInstead, "a file list, so Finder is asked to move it to the Trash")
        Check.equal(decide(press(nil, kVK_Delete, chord: .bare), surface: .unknown),
                    .passThrough, "no answer from Finder, so the key does what it always did")
        Check.equal(decide(press(nil, kVK_Delete, chord: .bare), surface: .text),
                    .passThrough, "and in text it deletes a character")
    }

    Check.suite("rule: ⌫ is rewritten going down and coming back up") {
        Check.equal(decide(press(nil, kVK_Delete, down: true, chord: .bare), surface: .fileList),
                    .trashInstead, "down")
        Check.equal(decide(press(nil, kVK_Delete, down: false, chord: .bare), surface: .fileList),
                    .trashInstead, "and up, so the press Finder sees is balanced")
    }

    Check.suite("rule: only a bare ⌫ is ours") {
        // ⌘⌫ is already Move to Trash and ⌥⌘⌫ is Delete Immediately. Touching
        // either would be rewriting a keystroke that already works.
        for chord in [Chord.command, .commandOption, Chord(option: true), Chord(shift: true)] {
            Check.equal(decide(press(nil, kVK_Delete, chord: chord), surface: .fileList),
                        .passThrough, "\(chord) belongs to Finder or to nobody")
        }
    }

    Check.suite("rule: ↩ opens, ⌘↩ renames, on a file list") {
        Check.equal(decide(press(nil, kVK_Return, chord: .bare), surface: .fileList),
                    .openInstead, "↩ opens the selection")
        Check.equal(decide(press(nil, kVK_ANSI_KeypadEnter, chord: .bare), surface: .fileList),
                    .openInstead, "and so does the keypad's Enter, which Finder treats alike")
        Check.equal(decide(press(nil, kVK_Return, chord: .command), surface: .fileList),
                    .renameInstead, "⌘↩ is where renaming went, and Finder had it unbound")
        Check.equal(decide(press(nil, kVK_Return, chord: .bare), surface: .unknown),
                    .passThrough, "with no answer from Finder, ↩ is left alone")
        Check.equal(decide(press(nil, kVK_Return, chord: .commandOption), surface: .fileList),
                    .passThrough, "⌥⌘↩ is somebody else's")
    }

    Check.suite("rule: these two keys work on every layout, including plain Dvorak") {
        // Unlike ZXCV, ⌫ and ↩ are in the same place under every layout and
        // produce the same character, so their rules read the key code alone and
        // an event carrying no character at all still decides correctly.
        Check.equal(decide(press(nil, kVK_Delete, chord: .bare), surface: .fileList),
                    .trashInstead, "⌫ with no character on the event")
        Check.equal(decide(press("\r", kVK_Return, chord: .bare), surface: .fileList),
                    .openInstead, "↩ with one")
    }

    Check.suite("rule: a fix that is switched off is not a rule at all") {
        Check.equal(decide(press(nil, kVK_Delete, chord: .bare), surface: .fileList,
                           enabled: [.cutAndPaste, .returnKey]), .passThrough, "⌫ off")
        Check.equal(decide(press(nil, kVK_Return, chord: .bare), surface: .fileList,
                           enabled: [.cutAndPaste, .deleteKey]), .passThrough, "↩ off")
        Check.equal(decide(press("x", kVK_ANSI_X), surface: .fileList,
                           enabled: [.deleteKey, .returnKey]), .passThrough, "⌘X off")
        for key in [kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_Delete, kVK_Return] {
            Check.equal(decide(press(nil, key, chord: .bare), surface: .fileList, enabled: .none),
                        .passThrough, "nothing on: key \(key) is untouched")
        }
    }

    Check.suite("rule: the three fixes do not interfere with each other") {
        // A cut is pending and the user trashes something else. The pasteboard
        // has not moved, so the cut has not either, and ⌘V still moves.
        Check.equal(decide(press(nil, kVK_Delete, chord: .bare), surface: .fileList, pending: true),
                    .trashInstead, "⌫ with a cut pending is still just ⌫")
        let cut = PendingCut(before: 10, pending: 11, awaitingCopy: false)
        for action in [FinderKeyAction.trashInstead, .openInstead, .renameInstead] {
            Check.equal(FinderCutLedger.after(action, isDown: true, cut: cut, changeCount: 11),
                        cut, "\(action) leaves the pending cut exactly as it was")
        }
    }

    // MARK: - the two other rewrites, on real events

    Check.suite("rewrite: ⌫ becomes ⌘⌫ and nothing else changes") {
        let e = event(kVK_Delete, down: true, flags: [])
        FinderKeyPolicy.apply(.trashInstead, to: e)
        Check.that(e.flags.contains(.maskCommand), "Command is set, though nobody held it")
        Check.equal(e.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_Delete),
                    "the key itself is not touched")
    }

    Check.suite("rewrite: ↩ becomes ⌘O, by key code and modifier") {
        let e = event(kVK_Return, down: true, flags: [])
        FinderKeyPolicy.apply(.openInstead, to: e)
        Check.equal(e.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_O),
                    "the key code is O's")
        Check.that(e.flags.contains(.maskCommand), "with Command set")
        if let cocoa = Check.unwrap(NSEvent(cgEvent: e), "still an NSEvent") {
            Check.equal(cocoa.charactersIgnoringModifiers, "o",
                        "and what AppKit matches a menu key equivalent against says o")
        }
    }

    Check.suite("rewrite: ⌘↩ becomes a plain ↩") {
        // The one rewrite that takes a modifier away rather than adding one.
        let e = event(kVK_Return, down: true, flags: [.maskCommand])
        FinderKeyPolicy.apply(.renameInstead, to: e)
        Check.that(!e.flags.contains(.maskCommand), "Command is gone")
        Check.equal(e.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_Return),
                    "and Return is still Return")
    }

    // MARK: - the object

    Check.suite("fixer: every fix off by default, and nothing is wrong while off") {
        let fixer = FinderFixes(defaults: scratchFinderDefaults())
        for fix in FinderFix.allCases {
            Check.that(!fixer.isEnabled(fix), "\(fix.label): off on a fresh install")
        }
        Check.that(!fixer.isAnythingEnabled, "so nothing touches anybody's keyboard")
        Check.equal(fixer.enabledFixes, .none, "and the tap would be told to do nothing")
        Check.equal(fixer.status, .off, "the shelf reports itself off")
        Check.isNil(fixer.explanation, "off is not a fault, so there is nothing to explain")
        Check.equal(fixer.reArmCount, 0, "nothing to re-arm")
        Check.that(fixer.tooltip(for: .cutAndPaste).contains("⌘X"),
                   "the tooltip still says what it would do")
        fixer.stop()
        Check.equal(fixer.status, .off, "stopping an already-stopped fixer is quiet")
    }

    Check.suite("fixer: the preference keys are the ones that shipped") {
        // Somebody who switched the cut fix on in 1.3 must find it still on.
        // A rename here would silently reset that choice.
        Check.equal(FinderFix.cutAndPaste.preferenceKey, "finderCutAndPaste", "the cut fix")
        Check.equal(FinderFix.deleteKey.preferenceKey, "finderDeleteKey", "the delete key")
        Check.equal(FinderFix.returnKey.preferenceKey, "finderReturnKey", "the return key")
        Check.equal(Set(FinderFix.allCases.map(\.preferenceKey)).count, FinderFix.allCases.count,
                    "and no two fixes share one")
    }

    Check.suite("fixer: each fix is switched on by itself") {
        let store = scratchFinderDefaults()
        let fixer = FinderFixes(defaults: store)
        fixer.setEnabled(.deleteKey, true)
        Check.that(fixer.isEnabled(.deleteKey), "the choice is persisted")
        Check.that(store.bool(forKey: "finderDeleteKey"), "in the store it was given")
        Check.that(!fixer.isEnabled(.cutAndPaste), "and its neighbours are untouched")
        Check.equal(fixer.enabledFixes, .deleteKey, "so the tap is told exactly one thing")

        fixer.setEnabled(.returnKey, true)
        Check.equal(fixer.enabledFixes, [.deleteKey, .returnKey], "and then two")
        fixer.setEnabled(.deleteKey, false)
        Check.equal(fixer.enabledFixes, .returnKey, "and back to one")
        Check.equal(fixer.setEnabled(.returnKey, false), .off, "the last one off returns to off")
        Check.isNil(fixer.explanation, "with nothing left to complain about")
    }

    Check.suite("fixer: switching on records the choice and reports honestly") {
        let store = scratchFinderDefaults()
        let fixer = FinderFixes(defaults: store)
        let status = fixer.setEnabled(.cutAndPaste, true)
        Check.that(fixer.isEnabled(.cutAndPaste), "the choice is persisted")
        Check.that(store.bool(forKey: "finderCutAndPaste"), "in the store it was given")

        if AccessibilityPermission.isGranted {
            // The tap follows Finder, so what the status says depends on what is
            // in front of the person running the tests, and it must say so
            // rather than guess.
            Check.equal(status, .ready(watching: finderIsFrontmost()),
                        "granted: on, and watching Finder exactly when Finder is frontmost")
            Check.isNil(fixer.explanation, "and there is nothing to explain")
        } else {
            Check.equal(status, .needsPermission, "not granted: says so")
            Check.that(fixer.explanation?.contains("Accessibility") == true,
                       "and explains where to go")
            Check.that(fixer.label(for: .cutAndPaste).contains("needs permission"),
                       "the menu says it too")
            Check.that(!fixer.label(for: .deleteKey).contains("needs permission"),
                       "but not for a fix nobody switched on")
        }

        Check.equal(fixer.setEnabled(.cutAndPaste, false), .off, "switching off returns to off")
        Check.that(!fixer.isEnabled(.cutAndPaste), "and the choice is persisted")
        Check.isNil(fixer.explanation, "with nothing left to complain about")
    }

    Check.suite("fixer: no keyboard tap exists unless Finder is in front") {
        // The privacy claim, asserted as a fact about threads rather than
        // believed. With anything but Finder frontmost there is no tap thread at
        // all, so there is nothing that could see a keystroke.
        let fixer = FinderFixes(defaults: scratchFinderDefaults())
        fixer.setEnabled(.cutAndPaste, true)
        let expected = AccessibilityPermission.isGranted && finderIsFrontmost() ? 1 : 0
        Check.equal(TapThreads.live(named: "taurine.finder").count, expected,
                    "a tap thread exists exactly when Finder is frontmost and we are allowed one")
        fixer.setEnabled(.cutAndPaste, false)
        Check.equal(TapThreads.live(named: "taurine.finder"), [],
                    "and switching off leaves none behind")
    }

    Check.suite("fixer: switching on and off forty times leaves nothing running") {
        let fixer = FinderFixes(defaults: scratchFinderDefaults())
        for _ in 0..<40 {
            fixer.setEnabled(.deleteKey, true)
            fixer.setEnabled(.deleteKey, false)
        }
        Check.equal(fixer.reArmCount, 0, "40 clean cycles are not a fault to report")
        Check.equal(TapThreads.live(named: "taurine.finder"), [], "and leave no tap thread")
    }

    // MARK: - the tap itself

    Check.suite("tap: arming, carrying a cut, and stopping") {
        guard AccessibilityPermission.isGranted else {
            Check.that(true, "skipped: this binary has no Accessibility permission")
            return
        }
        // Any process will do as the target: what is being tested is the tap's
        // thread and the cut it carries, neither of which asks anything of the
        // process whose Accessibility element it holds.
        let pid = ProcessInfo.processInfo.processIdentifier
        let carried = PendingCut(before: 4, pending: 5, awaitingCopy: false)

        guard case .armed(let tap) = FinderKeyTap.arm(finderPID: pid, fixes: .cutAndPaste,
                                                      carrying: carried) else {
            Check.that(false, "granted: the tap should arm")
            return
        }
        Check.equal(TapThreads.live(named: "taurine.finder").count, 1, "one tap thread is running")
        Check.equal(tap.cut, carried, "and the pending cut came across intact")
        Check.equal(tap.fixes, .cutAndPaste, "with the set of fixes it was armed for")

        // Switching a fix on does not rebuild anything: the callback reads a
        // scalar out of the cell it already has.
        tap.fixes = .all
        Check.equal(tap.fixes, .all, "and that set can be changed under a live tap")
        Check.equal(TapThreads.live(named: "taurine.finder").count, 1, "without a second thread")

        tap.stop()
        Check.equal(TapThreads.live(named: "taurine.finder"), [],
                    "stop() does not return while the thread can still run the callback")
        Check.equal(tap.cut, carried, "the cut is still readable once the thread is gone")
        Check.equal(tap.reArmCount, 0, "and taking it down is not counted as a re-arm")

        tap.stop()
        Check.equal(TapThreads.live(named: "taurine.finder"), [], "stopping twice is quiet")
    }

    Check.suite("tap: eight armed and stopped back to back pile up nothing") {
        guard AccessibilityPermission.isGranted else {
            Check.that(true, "skipped: this binary has no Accessibility permission")
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        var taps: [FinderKeyTap] = []
        for _ in 0..<8 {
            guard case .armed(let tap) = FinderKeyTap.arm(finderPID: pid, fixes: .all,
                                                          carrying: .nothingPending) else { continue }
            tap.stop()
            taps.append(tap)
        }
        Check.equal(taps.count, 8, "all eight armed")
        // One rather than zero for the same reason as the scroll fix: the join
        // waits for the thread to leave its run loop, which is the whole safety
        // property, but the kernel may still be reaping the pthread behind it.
        Check.that(TapThreads.live(named: "taurine.finder").count <= 1,
                   "no pile of live tap threads (saw \(TapThreads.live(named: "taurine.finder").count))")
    }
}

// MARK: - keystrokes

/// A keystroke, described rather than typed. Command-only unless said otherwise,
/// key-down unless said otherwise, because that is what nearly every case is.
private func press(_ character: String?, _ keyCode: Int,
                   down: Bool = true, chord: Chord = .command) -> KeyPress {
    KeyPress(keyCode: Int64(keyCode),
             character: character.flatMap { $0.unicodeScalars.first },
             isDown: down,
             chord: chord)
}

/// The rules under test, with the context they cannot work out themselves
/// defaulted to the hardest ordinary case: every fix switched on, nothing cut,
/// and a focus probe that came back with no answer at all.
///
/// `.unknown` is the default on purpose. It is the state in which the cut fix
/// must still fire and the two destructive keys must not, so every suite that
/// does not say otherwise is asserting that split as well as its own subject.
private func decide(_ key: KeyPress, surface: FinderSurface = .unknown,
                    enabled: FinderFixSet = .all, pending: Bool = false) -> FinderKeyAction {
    FinderKeyPolicy.decide(key, on: surface, enabled: enabled, cutIsPending: pending)
}

/// A real keyboard event, for the half of this that is about `CGEvent` fields.
private func event(_ keyCode: Int, down: Bool, flags: CGEventFlags) -> CGEvent {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down)!
    e.flags = flags
    return e
}

private func finderIsFrontmost() -> Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
}

/// A preferences domain that is not the user's.
private func scratchFinderDefaults() -> UserDefaults {
    let suite = "io.github.john-athan.taurine.tests.finder"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}
