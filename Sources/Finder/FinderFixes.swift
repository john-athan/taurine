import AppKit

/// The Finder shelf. ✂️🗑️↩️
///
/// Three keys that Finder answers differently from every other file manager
/// anyone has used, and one tap that fixes whichever of them you asked for.
///
///     ⌘X / ⌘V   cut and paste files, by becoming Copy and Move Item Here
///     ⌫         move the selection to the Trash, by becoming ⌘⌫
///     ⏎         open the selection, by becoming ⌘O, with rename moved to ⌘⏎
///
/// Apple's position on the first of those has always been that copy-then-move is
/// the safer pair, because a cut that never gets pasted has to mean something,
/// and on Windows it means the files sit in limbo looking half deleted. That
/// argument is about the *implementation* of cut, not about the keystroke, and
/// this settles it by not implementing cut at all. The other two are not even
/// arguments: ⌫ does nothing whatsoever in Finder today, and ⏎ renames while
/// every other file manager opens.
///
/// Owned here: the three preferences, the permission, the words in the menu, and
/// the tap's lifetime. Everything the tap thread does lives in `FinderKeyTap`,
/// and the rules it applies live in `FinderKeyPolicy`.
///
/// **The tap is armed only while Finder is frontmost.** Every other feature in
/// Taurine can be described by what it does; this one also has to be described
/// by what it can see, because a keyboard tap is the most invasive thing this
/// app has ever asked for. Tying its existence to Finder's activation makes
/// "Taurine cannot see you typing anywhere else" a fact about which threads
/// exist rather than a promise in a README. The workspace notification that
/// drives it was already being observed for the scroll fix, so this still adds
/// no timer and no polling.
///
/// **One tap, three switches.** Turning a fix on or off writes a scalar into the
/// cell the tap thread reads. No tap is rebuilt, and a fix that is off is
/// skipped by the first comparison in the callback.
///
/// **Nothing is armed twice.** Activation notifications arrive for every
/// application switch, including switching from Finder to Finder, so arming is
/// idempotent and takedown joins the tap thread before returning.
final class FinderFixes {

    /// What the shelf is doing, as far as it can tell. One status for all three
    /// fixes: they share a tap, a permission and a front application, so there
    /// is nothing a per-fix status could say that this one cannot.
    enum Status: Equatable {

        /// Every fix switched off. No tap, and no notifications observed.
        case off

        /// At least one fix on, and working. The tap itself exists only while
        /// Finder is frontmost, which is what the associated value says.
        case ready(watching: Bool)

        /// On, but macOS has not granted Accessibility.
        case needsPermission

        /// On, permission granted, and the tap still could not be armed.
        case blocked(String)
    }

    /// Called on the main thread whenever `status` changes, so the menu bar can
    /// redraw without asking.
    var onStatusChange: (() -> Void)?

    private(set) var status: Status = .off

    // MARK: - private state

    private let defaults: UserDefaults
    private let keyPrefix: String
    private var tap: FinderKeyTap?
    private var observing = false

    /// The pending cut, while no tap exists to hold it. A cut survives a trip to
    /// another application and back, so this outlives any one tap.
    private var carriedCut = PendingCut.nothingPending

    /// Re-arms counted by taps that have already been taken down. This feature
    /// retires a tap on every application switch, so unlike the scroll fix
    /// almost all of its history is in here.
    private var retiredReArms = 0

    /// `defaults` and the prefix are injectable so tests can drive the real
    /// object without writing to the user's preferences.
    init(defaults: UserDefaults = .standard, keyPrefix: String = "") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    deinit {
        onStatusChange = nil
        stop()
    }

    // MARK: - the switches

    /// Persisted, and every one of them off by default: they need a permission
    /// and they rewire keys people have been pressing for thirty years, so
    /// nobody gets any of this without choosing it.
    func isEnabled(_ fix: FinderFix) -> Bool { defaults.bool(forKey: keyPrefix + fix.preferenceKey) }

    /// Everything switched on right now, in the form the tap thread reads.
    var enabledFixes: FinderFixSet {
        FinderFix.allCases.reduce(into: FinderFixSet.none) { set, fix in
            if isEnabled(fix) { set.insert(fix.bit) }
        }
    }

    var isAnythingEnabled: Bool { !enabledFixes.isEmpty }

    /// Turn one fix on or off, remember the choice, and report where that left
    /// us. A `.needsPermission` result is not a failure to record: the
    /// preference stays on, and the fix starts by itself once the grant arrives.
    @discardableResult
    func setEnabled(_ fix: FinderFix, _ on: Bool) -> Status {
        defaults.set(on, forKey: keyPrefix + fix.preferenceKey)
        guard isAnythingEnabled else {
            stop()
            return status
        }
        // A live tap is told the new set rather than rebuilt: the cut it is
        // holding, and the thread it is running on, have nothing to do with
        // which fixes are switched on.
        tap?.fixes = enabledFixes
        return start()
    }

    /// Launch-time restore. Silent when the permission is missing: the menu says
    /// so, nothing pops up uninvited.
    @discardableResult
    func startIfEnabled() -> Status {
        isAnythingEnabled ? start() : settle(.off)
    }

    /// Start watching for Finder, and arm now if Finder is already frontmost.
    /// Idempotent.
    @discardableResult
    func start() -> Status {
        observe()
        guard AccessibilityPermission.isGranted else {
            disarm()
            return settle(.needsPermission)
        }
        return armIfFinderIsFrontmost()
    }

    /// Disarm everything and stop watching. Safe to call twice, safe to call
    /// having never started.
    func stop() {
        disarm()
        unobserve()
        settle(.off)
    }

    /// Ask macOS for Accessibility, then look again.
    func requestPermission() {
        AccessibilityPermission.request()
        refresh()
    }

    /// Re-examine everything that could have changed behind our back. Cheap
    /// enough to call whenever a menu opens, which is exactly when the answer is
    /// about to be shown to somebody.
    func refresh() {
        guard isAnythingEnabled else {
            stop()
            return
        }
        tap?.fixes = enabledFixes
        start()
    }

    // MARK: - following Finder

    /// Arm if Finder is the front application, take the tap down if it is not.
    /// This is the whole lifecycle rule, and it is called from exactly two
    /// places: `start`, and the activation notification.
    @discardableResult
    private func armIfFinderIsFrontmost() -> Status {
        guard let finder = frontmostFinder() else {
            disarm()
            // Not watching, but not broken either: the tap comes back with
            // Finder. A `.blocked` status is left standing, because whatever
            // stopped the last arming will stop the next one too.
            if case .blocked = status { return status }
            return settle(.ready(watching: false))
        }
        guard tap == nil else { return settle(.ready(watching: true)) }

        switch FinderKeyTap.arm(finderPID: finder, fixes: enabledFixes, carrying: carriedCut) {
        case .armed(let armed):
            tap = armed
            return settle(.ready(watching: true))
        case .refused:
            return settle(.blocked("macOS refused Taurine an event tap, even though Accessibility "
                                 + "permission is granted. Quitting and reopening Taurine usually clears this."))
        case .noRunLoop:
            return settle(.blocked("Taurine could not attach its keyboard tap to a run loop."))
        }
    }

    /// Take the tap down, keeping the pending cut. Returns with the tap thread
    /// already gone, because `FinderKeyTap.stop` joins it, which is what lets the
    /// cut be read back without a lock.
    private func disarm() {
        guard let tap else { return }
        tap.stop()
        // Settled here rather than carried: a cut still waiting for its copy is
        // only a reasonable thing to be while Finder is in front of you. See
        // `FinderCutLedger.resolve`.
        carriedCut = FinderCutLedger.resolve(tap.cut,
                                             changeCount: Int64(NSPasteboard.general.changeCount))
        retiredReArms += tap.reArmCount
        self.tap = nil
    }

    /// Finder's process id, if Finder is the front application.
    private func frontmostFinder() -> pid_t? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == Self.finderBundleID
        else { return nil }
        return front.processIdentifier
    }

    private static let finderBundleID = "com.apple.finder"

    private func observe() {
        guard !observing else { return }
        observing = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(somethingCameForward),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Finder can be relaunched underneath us, which invalidates the
        // Accessibility element the tap is holding. Cheaper to drop the tap and
        // let the next activation build a new one than to detect it later.
        center.addObserver(self, selector: #selector(somethingWentAway),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    private func unobserve() {
        guard observing else { return }
        observing = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Somebody switched applications. This is the only thing that arms or
    /// disarms the tap in normal use, and it is free: no timer, no polling, and
    /// it doubles as the moment a newly granted permission is noticed.
    @objc private func somethingCameForward() {
        guard isAnythingEnabled else { return }
        guard AccessibilityPermission.isGranted else {
            disarm()
            settle(.needsPermission)
            return
        }
        if case .needsPermission = status { settle(.ready(watching: false)) }
        armIfFinderIsFrontmost()
    }

    @objc private func somethingWentAway(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier == Self.finderBundleID else { return }
        disarm()
        settle(.ready(watching: false))
    }

    @discardableResult
    private func settle(_ new: Status) -> Status {
        guard new != status else { return status }
        status = new
        onStatusChange?()
        return new
    }

    // MARK: - what to show

    /// Menu item text. Carries the one state that must be visible without
    /// hovering: switched on and not working.
    func label(for fix: FinderFix) -> String {
        guard isEnabled(fix) else { return fix.label }
        switch status {
        case .off, .ready:     return fix.label
        case .needsPermission: return fix.label + " (needs permission)"
        case .blocked:         return fix.label + " (not working)"
        }
    }

    /// Tooltip: what the fix does when off, what it is doing when on, and what
    /// is wrong when it is wrong. The sentence about what Taurine can see is not
    /// decoration; it is the thing somebody switching on a keyboard tap deserves
    /// to be told at the moment they switch it on.
    func tooltip(for fix: FinderFix) -> String {
        guard isEnabled(fix) else { return fix.explainer + "\n\nNeeds Accessibility permission." }
        switch status {
        case .off, .ready(false):
            return fix.explainer
                 + "\n\nOn. The keyboard tap exists only while Finder is the front application, so "
                 + "it is not running at this moment. Taurine reads the key code of each key you "
                 + "press in Finder and nothing else: no text, no other application, nothing stored."
                 + reArmNote
        case .ready(true):
            return fix.explainer
                 + "\n\nOn, and watching Finder now. Taurine reads the key code of each key you "
                 + "press in Finder and nothing else: no text, no other application, nothing stored."
                 + reArmNote
        case .needsPermission, .blocked:
            return explanation ?? ""
        }
    }

    /// Non-nil exactly when something is switched on and not working, so a
    /// caller can use it as the test for "should I show the fix-it item".
    var explanation: String? {
        switch status {
        case .off, .ready:
            return nil
        case .needsPermission:
            return AccessibilityPermission.missingGrantExplanation(
                toDo: "see the keys you press in Finder")
        case .blocked(let why):
            return why
        }
    }

    /// How many times macOS has disabled a tap of ours and we have re-armed it,
    /// over every tap this feature has armed. Zero on a healthy machine.
    var reArmCount: Int { retiredReArms + (tap?.reArmCount ?? 0) }

    private var reArmNote: String {
        reArmCount == 0 ? "" : "\nRe-armed \(reArmCount) time(s) after macOS switched the tap off."
    }
}

/// The three fixes, and everything about them that is words rather than rules.
///
/// Kept next to the owner rather than next to the policy because none of it
/// reaches the tap thread: the thread gets `FinderFixSet`, a scalar, and the
/// menu gets these.
enum FinderFix: CaseIterable {
    case cutAndPaste
    case deleteKey
    case returnKey

    /// The bit the tap thread reads.
    var bit: FinderFixSet {
        switch self {
        case .cutAndPaste: return .cutAndPaste
        case .deleteKey:   return .deleteKey
        case .returnKey:   return .returnKey
        }
    }

    /// Unchanged from the version that shipped alone, so switching on the cut
    /// fix in 1.3 stays switched on in 1.4.
    var preferenceKey: String {
        switch self {
        case .cutAndPaste: return "finderCutAndPaste"
        case .deleteKey:   return "finderDeleteKey"
        case .returnKey:   return "finderReturnKey"
        }
    }

    var label: String {
        switch self {
        case .cutAndPaste: return "Cut and paste files in Finder"
        case .deleteKey:   return "Delete key moves files to the Trash"
        case .returnKey:   return "Return opens files (⌘↩ renames)"
        }
    }

    /// What it does, in the words somebody hovering the item needs.
    var explainer: String {
        switch self {
        case .cutAndPaste:
            return "⌘X marks files to move and ⌘V moves them, by turning ⌘X into Copy and ⌘V into "
                 + "Finder's own Move Item Here. Finder does the moving, so progress, name clashes "
                 + "and Undo all behave normally."
        case .deleteKey:
            return "⌫ moves the selection to the Trash, by becoming ⌘⌫, which is what Finder has "
                 + "always answered. Nothing is deleted: the files go to the Trash and ⌘Z brings "
                 + "them back. Inside a rename field ⌫ still deletes a character."
        case .returnKey:
            return "↩ opens the selection, by becoming ⌘O, and renaming moves to ⌘↩, which Finder "
                 + "leaves unused. Inside a rename field ↩ still commits the new name."
        }
    }
}
