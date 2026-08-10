import Foundation

/// ⇧⌘V everywhere: the dictionary arithmetic, and nothing else.
///
/// This fix has no tap, no thread and no permission, so there is nothing here
/// about lifetimes. What there is instead is the one dangerous property: the
/// preference it writes is a shared one. System Settings writes to the same
/// dictionary, so every test below is really the same question asked from a
/// different angle, which is whether switching this on and off again leaves
/// somebody else's entries exactly as they were found.
///
/// Nothing here touches the machine's real preferences. The store is a
/// dictionary in memory, which is the whole reason the rule was written as
/// functions over a dictionary rather than as code that reaches for
/// `CFPreferences` in the middle of deciding something.
func runPastePlainTextTests() {

    Check.suite("rule: switching on binds every title it knows") {
        let after = PastePlainTextRule.adding(to: [:])
        Check.equal(after.count, PastePlainTextRule.titles.count, "one entry per title")
        for title in PastePlainTextRule.titles {
            Check.equal(after[title], "@$v", "\(title) is on ⇧⌘V")
        }
        Check.that(PastePlainTextRule.isInstalled(in: after), "and the fix reads as on")
    }

    Check.suite("rule: the shortcut is spelled the way AppKit spells it") {
        // `@` Command, `$` Shift, and the letter in lower case. This is what
        // System Settings writes for the same choice, and it was read back off a
        // live TextEdit menu as ⇧⌘V before it was written down here.
        Check.equal(PastePlainTextRule.shortcut, "@$v", "⇧⌘V")
    }

    Check.suite("rule: the English and German titles are both bound") {
        // The match is on the title an application actually shows, and an
        // application in one language on a system in another is ordinary. Both
        // were read off live menu bars rather than guessed: a German TextEdit
        // calls it "Einsetzen und Stil anpassen" and went on showing ⌥⇧⌘V while
        // only the English entry was written.
        Check.that(PastePlainTextRule.titles.contains("Paste and Match Style"), "English")
        Check.that(PastePlainTextRule.titles.contains("Einsetzen und Stil anpassen"), "German")
    }

    Check.suite("rule: switching off takes back exactly what it put in") {
        let empty: [String: String] = [:]
        let round = PastePlainTextRule.removing(from: PastePlainTextRule.adding(to: empty))
        Check.equal(round, empty, "on and off again is a no-op on an empty dictionary")
        Check.that(!PastePlainTextRule.isInstalled(in: round), "and the fix reads as off")
    }

    Check.suite("rule: somebody else's shortcuts are not ours to touch") {
        // The property that matters most: this dictionary is shared with System
        // Settings, so anything in it that we did not write is a choice somebody
        // made deliberately.
        let theirs = ["Show Inspector": "@~i", "Merge All Windows": "^$m"]
        let on = PastePlainTextRule.adding(to: theirs)
        for (title, key) in theirs {
            Check.equal(on[title], key, "\(title) is left exactly as it was")
        }
        let off = PastePlainTextRule.removing(from: on)
        Check.equal(off, theirs, "and switching off puts the dictionary back as it was found")
    }

    Check.suite("rule: a title somebody has already bound by hand is left alone") {
        // Overwriting it would be bad enough. Worse, switching off afterwards
        // could not restore it, because nothing would remember what it had been.
        let byHand = ["Paste and Match Style": "^~$v"]
        let on = PastePlainTextRule.adding(to: byHand)
        Check.equal(on["Paste and Match Style"], "^~$v", "their binding survives")
        Check.equal(on["Einsetzen und Stil anpassen"], "@$v", "the other title is still ours to bind")
        Check.that(!PastePlainTextRule.isInstalled(in: on),
                   "and the menu must not claim to be fully on")
        Check.equal(PastePlainTextRule.claimedByHand(in: on), ["Paste and Match Style"],
                    "so the tooltip can name what it left alone")

        Check.equal(PastePlainTextRule.removing(from: on), byHand,
                    "switching off removes only the entry we made")
    }

    Check.suite("rule: an entry of ours that somebody has since changed is theirs now") {
        let changed = ["Paste and Match Style": "@$b", "Einsetzen und Stil anpassen": "@$v"]
        Check.equal(PastePlainTextRule.removing(from: changed),
                    ["Paste and Match Style": "@$b"],
                    "the changed one stays, ours goes")
    }

    Check.suite("rule: switching on twice is the same as switching on once") {
        let once = PastePlainTextRule.adding(to: [:])
        Check.equal(PastePlainTextRule.adding(to: once), once, "idempotent")
        let off = PastePlainTextRule.removing(from: [:])
        Check.equal(off, [:], "and so is switching off something that was never on")
    }

    // MARK: - the object over a store that is not the machine's

    Check.suite("fix: the preference is the state, so the two cannot drift") {
        let store = MemoryKeyEquivalents()
        let fix = PastePlainText(store: store)
        Check.that(!fix.isEnabled, "off, because the dictionary says so")

        fix.setEnabled(true)
        Check.that(fix.isEnabled, "on, because the dictionary says so")
        Check.that(fix.tooltip.contains("next start"),
                   "and the tooltip says applications pick it up when they restart")

        // Somebody undoes it in System Settings. Nothing of ours is notified,
        // and nothing needs to be: the next look at the menu asks the
        // dictionary rather than a flag of our own.
        store.contents = [:]
        Check.that(!fix.isEnabled, "a change made elsewhere is simply the truth")

        fix.setEnabled(false)
        Check.equal(store.contents, [:], "and switching off an already-off fix writes nothing new")
    }

    Check.suite("fix: an empty dictionary is removed rather than stored empty") {
        let store = MemoryKeyEquivalents()
        let fix = PastePlainText(store: store)
        fix.setEnabled(true)
        fix.setEnabled(false)
        Check.that(store.contents.isEmpty, "the key is left as it was found: absent")
        Check.equal(store.writes, 2, "and it took exactly one write each way")
    }
}

/// A key equivalent store that is a dictionary. The real one writes a
/// preferences domain shared by every application on the Mac, which is not
/// somewhere a test run may leave footprints.
private final class MemoryKeyEquivalents: KeyEquivalentStore {
    var contents: [String: String] = [:]
    var writes = 0

    func read() -> [String: String] { contents }

    func write(_ equivalents: [String: String]) {
        contents = equivalents
        writes += 1
    }
}
