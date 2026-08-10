import AppKit

/// The interpreter. 🌀
///
/// Sits between the devices and the applications, reads every scroll event once,
/// and reverses the ones ADR 0004 says the system got backwards. Everything hard
/// about it is a consequence of where it sits.
///
/// **It runs on its own thread.** A tap that is slow to answer is not slowed
/// down, it is switched off: macOS disables it and every scroll event after that
/// goes through unhelped. Taurine's main thread waits on `osascript` for the lid
/// guard, on `NSAlert.runModal`, on menu tracking. Any of those would be enough
/// to lose the tap. So the tap gets a thread whose run loop does nothing else,
/// and the callback never touches the main thread or the fixer object. All of
/// that lives in `ScrollTap`, which owns the thread and the memory they share;
/// this type owns the policy, the preference and the words in the menu.
///
/// **Nothing polls.** The setting arrives as a distributed notification. App
/// activation is used as a second, free chance to notice both a setting change
/// that never sent one and an Accessibility grant that has just been made, which
/// is what makes "switch it on in System Settings and come back" work without a
/// restart or a timer. The badge still reads `0 timers`.
///
/// Two traps for the next reader, and neither is here. The order of the writes
/// in `ScrollCorrection.negateDeltas` is load bearing, and the order of the
/// teardown in `ScrollTap.stop` is the difference between a clean stop and a
/// use-after-free on the tap thread.
final class ScrollDirectionFixer {

    /// What the feature is doing, as far as it can tell.
    enum Status: Equatable {

        /// Switched off. The tap does not exist.
        case off

        /// On and working. The associated value is the class of device being
        /// reversed, which is always the one that disagrees with the system.
        case correcting(ScrollDevice)

        /// On, but macOS has not granted Accessibility. See
        /// `AccessibilityPermission.missingGrantExplanation(toDo:)`.
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
    private var tap: ScrollTap?
    private var observing = false

    /// Re-arms counted by taps that have already been taken down. A tap's own
    /// counter dies with it, and the diagnostic is meant to answer "has this
    /// been happening while Taurine has been running", so the total outlives
    /// any one tap.
    private var retiredReArms = 0

    /// `defaults` and `key` are injectable so tests can drive the real object
    /// without writing to the user's preferences.
    init(defaults: UserDefaults = .standard, key: String = "fixScrollDirection") {
        self.defaults = defaults
        self.key = key
    }

    deinit {
        // Nothing may call back into a half-dead object.
        onStatusChange = nil
        stop()
    }

    // MARK: - the switch

    /// Persisted, and off by default: this is the one feature that asks the
    /// system for a permission, so nobody gets it without choosing it.
    var isEnabled: Bool { defaults.bool(forKey: key) }

    /// Turn the correction on or off, remember the choice, and report where that
    /// left us. A `.needsPermission` result is not a failure to record: the
    /// preference stays on, and the correction starts by itself once the grant
    /// arrives.
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

    /// Arm the tap and start listening for the things that change the answer.
    /// Idempotent.
    @discardableResult
    func start() -> Status {
        observe()
        guard tap == nil else { return status }
        guard AccessibilityPermission.isGranted else { return settle(.needsPermission) }

        let natural = SystemScrollDirection.isNatural
        switch ScrollTap.arm(systemScrollsNaturally: natural) {
        case .armed(let armed):
            tap = armed
            return settle(.correcting(reversedClass(whenNatural: natural)))
        case .refused:
            return settle(.blocked("macOS refused Taurine an event tap, even though Accessibility "
                                 + "permission is granted. Quitting and reopening Taurine usually clears this."))
        case .noRunLoop:
            return settle(.blocked("Taurine could not attach its scroll tap to a run loop."))
        }
    }

    /// Disarm everything and stop watching. Safe to call twice, safe to call
    /// having never started.
    func stop() {
        disarmTap()
        unobserve()
        settle(.off)
    }

    /// Take down the tap and its thread, leaving the observers in place. Used
    /// when the feature is still switched on but cannot currently run, so that
    /// the thing that fixes it (a grant arriving) is still being watched for.
    ///
    /// Returns with the tap thread already gone, because `ScrollTap.stop` joins
    /// it. That is what lets a caller say "the tap is down" and be right.
    private func disarmTap() {
        guard let tap else { return }
        tap.stop()
        // Read after the stop, so nothing can still be counting.
        retiredReArms += tap.reArmCount
        self.tap = nil
    }

    // MARK: - staying current

    /// Re-examine everything that could have changed behind our back. Cheap
    /// enough to call whenever a menu opens, which is exactly when the answer is
    /// about to be shown to somebody.
    func refresh() {
        guard isEnabled else {
            stop()
            return
        }
        if tap == nil {
            start()             // permission may have arrived since we last tried
            return
        }
        guard AccessibilityPermission.isGranted else {
            // The grant can be taken away mid-session, which kills the tap
            // without telling us. Fall back to the honest state, but keep
            // watching, because it can just as easily come back.
            disarmTap()
            settle(.needsPermission)
            return
        }
        reloadSystemDirection()
    }

    /// Ask macOS for Accessibility, then look again. Wired to the menu item that
    /// only appears when the permission is what is missing.
    func requestPermission() {
        AccessibilityPermission.request()
        refresh()
    }

    /// Re-read the global setting and hand the new answer to the tap thread.
    private func reloadSystemDirection() {
        guard let tap else { return }
        let natural = SystemScrollDirection.isNatural
        tap.setSystemScrollsNaturally(natural)
        settle(.correcting(reversedClass(whenNatural: natural)))
    }

    /// Whichever class disagrees with the system is the one being reversed.
    private func reversedClass(whenNatural natural: Bool) -> ScrollDevice {
        natural ? .wheel : .continuousSurface
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(systemDirectionChanged),
            name: SystemScrollDirection.changeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(somethingCameForward),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    private func unobserve() {
        guard observing else { return }
        observing = false
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func systemDirectionChanged() { reloadSystemDirection() }

    /// Somebody switched apps. Free, and it is how coming back from System
    /// Settings takes effect: a new grant or a changed setting is picked up
    /// without a timer and without a relaunch.
    @objc private func somethingCameForward() { refresh() }

    @discardableResult
    private func settle(_ new: Status) -> Status {
        guard new != status else { return status }
        status = new
        onStatusChange?()
        return new
    }

    // MARK: - what to show

    /// Menu item text. Carries the one state that must be visible without
    /// hovering, because a switched-on feature that does nothing is the whole
    /// failure mode this design is trying to avoid.
    var label: String {
        switch status {
        case .off, .correcting:  return "Scroll direction follows the device"
        case .needsPermission:   return "Scroll direction follows the device (needs permission)"
        case .blocked:           return "Scroll direction follows the device (not working)"
        }
    }

    /// Tooltip for that item: what it does when off, what it is doing when on,
    /// and what is wrong when it is wrong.
    var tooltip: String {
        switch status {
        case .off:
            return "Trackpads and the Magic Mouse scroll naturally, wheel mice scroll the "
                 + "traditional way, whichever way the system setting is pointing. "
                 + "Needs Accessibility permission."
        case .correcting(.wheel):
            return "On. The system scrolls naturally, so Taurine reverses wheel mice and leaves "
                 + "trackpads alone." + reArmNote
        case .correcting(.continuousSurface):
            return "On. The system scrolls the traditional way, so Taurine reverses trackpads and "
                 + "the Magic Mouse and leaves wheel mice alone." + reArmNote
        case .needsPermission, .blocked:
            return explanation ?? ""
        }
    }

    /// Non-nil exactly when the feature is switched on and not working, so a
    /// caller can use it as the test for "should I show the fix-it item".
    var explanation: String? {
        switch status {
        case .off, .correcting:  return nil
        case .needsPermission:   return AccessibilityPermission.missingGrantExplanation(toDo: "change scroll events")
        case .blocked(let why):  return why
        }
    }

    /// How many times macOS has disabled the tap and we have re-armed it, over
    /// every tap this fixer has armed. Zero on a healthy machine; a climbing
    /// number means something is stalling the tap thread and is worth seeing.
    ///
    /// Taurine switching its own tap off is not counted. It used to be, which
    /// made the number blame macOS for something Taurine did: see
    /// `ScrollTap.stop`.
    var reArmCount: Int { retiredReArms + (tap?.reArmCount ?? 0) }

    private var reArmNote: String {
        reArmCount == 0 ? "" : "\nRe-armed \(reArmCount) time(s) after macOS switched the tap off."
    }
}
