import AppKit

/// The second entry on the shelf. ✂️
///
/// ⌘X in Finder does nothing. It has never done anything, on any version of
/// macOS, for files. The move exists, as ⌥⌘V ("Move Item Here"), and Apple's
/// position has always been that copy-then-move is the safer pair because a cut
/// that never gets pasted has to mean something, and on Windows it means the
/// files sit in limbo looking half-deleted. That argument is about the
/// *implementation* of cut, not about the keystroke, and this feature settles it
/// by not implementing cut at all: ⌘X becomes ⌘C, ⌘V becomes ⌥⌘V, and the file
/// does not move until you paste. A cut you never paste is a copy you never
/// pasted, which is nothing.
///
/// Owned here: the preference, the permission, the words in the menu, and the
/// tap's lifetime. Everything the tap thread does lives in `FinderKeyTap`, and
/// the rule it applies lives in `FinderCutPolicy`.
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
/// **Nothing is armed twice.** Activation notifications arrive for every
/// application switch, including switching from Finder to Finder, so arming is
/// idempotent and takedown joins the tap thread before returning.
final class FinderCutPaste {

    /// What the feature is doing, as far as it can tell.
    enum Status: Equatable {

        /// Switched off. No tap, and no notifications observed.
        case off

        /// On and working. The tap itself exists only while Finder is frontmost,
        /// which is what the associated value says.
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
    private let key: String
    private var tap: FinderKeyTap?
    private var observing = false

    /// The pending cut, while no tap exists to hold it. A cut survives a trip to
    /// another application and back, so this outlives any one tap.
    private var carriedCut = PendingCut.nothingPending

    /// Re-arms counted by taps that have already been taken down. This feature
    /// retires a tap on every application switch, so unlike the scroll fix
    /// almost all of its history is in here.
    private var retiredReArms = 0

    /// `defaults` and `key` are injectable so tests can drive the real object
    /// without writing to the user's preferences.
    init(defaults: UserDefaults = .standard, key: String = "finderCutAndPaste") {
        self.defaults = defaults
        self.key = key
    }

    deinit {
        onStatusChange = nil
        stop()
    }

    // MARK: - the switch

    /// Persisted, and off by default: it needs a permission and it rewires two
    /// keys people have been pressing for thirty years, so nobody gets it
    /// without choosing it.
    var isEnabled: Bool { defaults.bool(forKey: key) }

    /// Turn the fix on or off, remember the choice, and report where that left
    /// us. A `.needsPermission` result is not a failure to record: the
    /// preference stays on, and the fix starts by itself once the grant arrives.
    @discardableResult
    func setEnabled(_ on: Bool) -> Status {
        defaults.set(on, forKey: key)
        guard on else {
            stop()
            return status
        }
        return start()
    }

    /// Launch-time restore. Silent when the permission is missing: the menu says
    /// so, nothing pops up uninvited.
    @discardableResult
    func startIfEnabled() -> Status {
        isEnabled ? start() : settle(.off)
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
        guard isEnabled else {
            stop()
            return
        }
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

        switch FinderKeyTap.arm(finderPID: finder, carrying: carriedCut) {
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
        guard isEnabled else { return }
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
    var label: String {
        switch status {
        case .off, .ready:     return "Cut and paste files in Finder"
        case .needsPermission: return "Cut and paste files in Finder (needs permission)"
        case .blocked:         return "Cut and paste files in Finder (not working)"
        }
    }

    /// Tooltip: what it does when off, what it is doing when on, and what is
    /// wrong when it is wrong. The sentence about what Taurine can see is not
    /// decoration; it is the thing somebody switching on a keyboard tap deserves
    /// to be told at the moment they switch it on.
    var tooltip: String {
        switch status {
        case .off:
            return "⌘X marks files to move and ⌘V moves them, by turning ⌘X into Copy and ⌘V into "
                 + "Finder's own Move Item Here. Finder does the moving, so progress, name "
                 + "clashes and Undo all behave normally. Needs Accessibility permission."
        case .ready(let watching):
            return (watching
                    ? "On, and watching Finder now. "
                    : "On. The keyboard tap exists only while Finder is the front application, so "
                    + "it is not running at this moment. ")
                 + "Taurine reads the key code of each key you press in Finder and nothing else: "
                 + "no text, no other application, nothing stored."
                 + reArmNote
        case .needsPermission, .blocked:
            return explanation ?? ""
        }
    }

    /// Non-nil exactly when the feature is switched on and not working, so a
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
