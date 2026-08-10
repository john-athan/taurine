import Foundation

/// One shortcut for pasting as plain text, everywhere. ⇧⌘V
///
/// The keystroke exists in every application that can paste formatted text. It
/// is just not the same keystroke twice. Chrome, Firefox, VS Code and Slack put
/// it on ⇧⌘V; Pages, Keynote, Mail, Notes, Safari and TextEdit put it on
/// ⌥⇧⌘V. So whether the shortcut your hands know works depends on which window
/// happens to be in front, which is the worst possible property for a shortcut.
///
/// **This is the one fix on the shelf that is not a tap.** macOS already has the
/// mechanism: a menu item's key equivalent can be overridden by title, for one
/// application or for all of them, and the override lives in a single
/// preference. System Settings exposes it under Keyboard ▸ Keyboard Shortcuts ▸
/// App Shortcuts, where getting this right means knowing that the menu item is
/// called "Paste and Match Style", typing it exactly, and repeating the exercise
/// in whatever language your applications are in. Taurine's contribution is
/// knowing the titles, not owning the machinery.
///
/// What that buys, compared to rewriting the keystroke in a tap:
///
///   * No permission. Nothing to grant, nothing to re-grant after an update.
///   * No tap, no thread, no callback. Nothing runs when you press the key.
///   * It cannot be wrong about what you are doing, because it never looks. The
///     menu either has an item by that name or it does not.
///   * Reversing it is deleting a dictionary entry, and the same checkbox does
///     it.
///
/// And what it costs:
///
///   * **Applications pick it up when they next start.** The menu is built at
///     launch, so anything already running keeps the old shortcut until it is
///     quit and reopened.
///   * **Only real menus.** An application that draws its own menu bar, or
///     handles ⇧⌘V without a menu item, is untouched. In practice those are the
///     ones that already do the right thing.
///   * **Only these titles.** An application that calls it something else keeps
///     whatever it had.
enum PastePlainTextRule {

    /// AppKit's shorthand for a key equivalent: `@` Command, `$` Shift, `~`
    /// Option, `^` Control. This is ⇧⌘V, and it is exactly what System Settings
    /// writes for the same choice.
    static let shortcut = "@$v"

    /// The menu item titles this binds, checked against live menu bars rather
    /// than guessed. English is what Chrome and every Apple application use;
    /// the German title was read out of a Finder and a TextEdit forced into
    /// German, because the match is on the title an application actually shows,
    /// and an application in one language on a system in another is ordinary.
    ///
    /// A title no application has is not a risk, it is a line that never
    /// matches. The risk runs the other way: a title used by an item that is
    /// *not* a plain paste would move that item onto ⇧⌘V. So this list stays
    /// short and stays measured.
    static let titles = [
        "Paste and Match Style",
        "Einsetzen und Stil anpassen",
    ]

    /// Add our entries, leaving everything else alone.
    ///
    /// A title somebody has already bound by hand keeps their binding. That is
    /// not politeness for its own sake: this preference is where System
    /// Settings writes too, so an entry we did not make is a choice somebody
    /// made, and quietly overwriting it would also mean `removing` could not
    /// tell what to put back.
    static func adding(to existing: [String: String]) -> [String: String] {
        var next = existing
        for title in titles where next[title] == nil { next[title] = shortcut }
        return next
    }

    /// Take our entries back out, and only ours. An entry whose value is not
    /// the one we write belongs to somebody else and stays.
    static func removing(from existing: [String: String]) -> [String: String] {
        var next = existing
        for title in titles where next[title] == shortcut { next.removeValue(forKey: title) }
        return next
    }

    /// On when every title we know about is bound the way we bind it.
    static func isInstalled(in existing: [String: String]) -> Bool {
        titles.allSatisfy { existing[$0] == shortcut }
    }

    /// Titles somebody else got to first, so the menu can say so rather than
    /// showing a checkbox that is on while one of the two entries is not ours.
    static func claimedByHand(in existing: [String: String]) -> [String] {
        titles.filter { existing[$0] != nil && existing[$0] != shortcut }
    }
}

/// Where key equivalent overrides live: one key of the preferences domain that
/// applies to every application.
///
/// A protocol only so the rule above can be tested against a dictionary rather
/// than against the machine's real preferences, which a test has no business
/// writing to.
protocol KeyEquivalentStore {
    func read() -> [String: String]
    func write(_ equivalents: [String: String])
}

/// The real one: `NSUserKeyEquivalents` in the domain that applies to any
/// application, for the current user, on any host. That is precisely where
/// System Settings writes App Shortcuts for "All Applications", and writing it
/// with `CFPreferencesSetValue` touches that one key and nothing else in a
/// domain that holds a large part of how this Mac is set up.
struct GlobalKeyEquivalents: KeyEquivalentStore {

    private let key = "NSUserKeyEquivalents" as CFString
    private let app = kCFPreferencesAnyApplication
    private let user = kCFPreferencesCurrentUser
    private let host = kCFPreferencesAnyHost

    func read() -> [String: String] {
        (CFPreferencesCopyValue(key, app, user, host) as? [String: String]) ?? [:]
    }

    /// An empty dictionary removes the key rather than leaving an empty one
    /// behind, so switching this off leaves the domain as it was found.
    func write(_ equivalents: [String: String]) {
        CFPreferencesSetValue(key,
                              equivalents.isEmpty ? nil : (equivalents as CFDictionary),
                              app, user, host)
        CFPreferencesSynchronize(app, user, host)
    }
}

/// The menu's view of it. No state of its own: the preference *is* the state, so
/// a checkbox switched on in System Settings and one switched on here are the
/// same thing, and neither can drift from the other.
final class PastePlainText {

    private let store: KeyEquivalentStore

    init(store: KeyEquivalentStore = GlobalKeyEquivalents()) {
        self.store = store
    }

    var isEnabled: Bool { PastePlainTextRule.isInstalled(in: store.read()) }

    func setEnabled(_ on: Bool) {
        let existing = store.read()
        store.write(on ? PastePlainTextRule.adding(to: existing)
                       : PastePlainTextRule.removing(from: existing))
    }

    let label = "⇧⌘V pastes as plain text everywhere"

    var tooltip: String {
        let what = "Chrome, Firefox, VS Code and Slack paste as plain text on ⇧⌘V. Apple's "
                 + "applications put the same command on ⌥⇧⌘V. This makes ⇧⌘V mean it everywhere, "
                 + "by writing the same key equivalent System Settings would write under "
                 + "Keyboard Shortcuts ▸ App Shortcuts.\n\n"
                 + "No permission, no keyboard tap: nothing of Taurine's runs when you press it."
        let taken = PastePlainTextRule.claimedByHand(in: store.read())
        let mine = taken.isEmpty ? "" :
            "\n\nLeft alone because you already bound it yourself: " + taken.joined(separator: ", ")
        return what
             + (isEnabled ? "\n\nOn. Applications pick this up when they next start."
                          : "")
             + mine
    }
}
