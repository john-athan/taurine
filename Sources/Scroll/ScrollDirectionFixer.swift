import AppKit
import CoreGraphics

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
/// and the callback never touches the main thread or the fixer object.
///
/// **The callback reads one number.** The current system setting is cached as an
/// `Int32` in a heap cell handed to the tap as its `userInfo`. The main thread
/// stores into it when the setting changes; the tap thread loads it per event.
/// An aligned 32-bit scalar cannot tear, and the worst outcome of the race is
/// that one event on the boundary of changing the setting in System Settings
/// uses the previous answer. That is a better trade than a lock the main thread
/// could be holding while blocked in a modal dialog.
///
/// **Nothing polls.** The setting arrives as a distributed notification. App
/// activation is used as a second, free chance to notice both a setting change
/// that never sent one and an Accessibility grant that has just been made, which
/// is what makes "switch it on in System Settings and come back" work without a
/// restart or a timer. The badge still reads `0 timers`.
///
/// The trap for the next reader is in `ScrollCorrection.negateDeltas`: the three
/// delta fields are not independent, and the order of the writes is load bearing.
final class ScrollDirectionFixer {

    /// What the feature is doing, as far as it can tell.
    enum Status: Equatable {

        /// Switched off. The tap does not exist.
        case off

        /// On and working. The associated value is the class of device being
        /// reversed, which is always the one that disagrees with the system.
        case correcting(ScrollDevice)

        /// On, but macOS has not granted Accessibility. See
        /// `ScrollPermission.missingGrantExplanation`.
        case needsPermission

        /// On, permission granted, and the tap still could not be armed.
        case blocked(String)
    }

    /// Called on the main thread whenever `status` changes, so the menu bar can
    /// redraw without asking.
    var onStatusChange: (() -> Void)?

    private(set) var status: Status = .off

    // MARK: - shared with the tap thread

    /// The only memory the two threads share. Deliberately a plain struct behind
    /// a raw pointer: the callback must not retain, release, or allocate.
    private struct TapState {
        /// 1 when `com.apple.swipescrolldirection` is on. Written by the main
        /// thread, read once per scroll event.
        var systemScrollsNaturally: Int32
        /// The tap itself, unretained, so the callback can re-arm it without
        /// touching ARC. The fixer holds the strong reference.
        var tap: UnsafeMutableRawPointer?
        /// How many times macOS has disabled us and we have come back. Written
        /// by the tap thread, read by the menu for diagnostics.
        var reArms: Int32
    }

    private let shared = UnsafeMutablePointer<TapState>.allocate(capacity: 1)

    /// The whole hot path. One branch, six field reads and six writes at most,
    /// no allocation, no lock, and no call into this object or the main thread.
    /// The recovery branch below is the only one that touches ARC, and it runs
    /// about as often as macOS decides to switch us off.
    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let shared = info.assumingMemoryBound(to: TapState.self)

        if type == .scrollWheel {
            ScrollCorrection.apply(to: event,
                                   systemScrollsNaturally: shared.pointee.systemScrollsNaturally != 0)
        } else if let port = shared.pointee.tap {
            // The only other types we can be sent are the two the system uses to
            // tell us it has switched us off: `.tapDisabledByTimeout` when a
            // callback took too long, `.tapDisabledByUserInput` under a
            // secure-input or debugger condition. Both are recoverable by simply
            // enabling the same port again, on this thread, right now.
            CGEvent.tapEnable(tap: Unmanaged<CFMachPort>.fromOpaque(port).takeUnretainedValue(),
                              enable: true)
            shared.pointee.reArms &+= 1
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - private state

    private let defaults: UserDefaults
    private let key: String
    private var tap: CFMachPort?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var observing = false

    /// `defaults` and `key` are injectable so tests can drive the real object
    /// without writing to the user's preferences.
    init(defaults: UserDefaults = .standard, key: String = "fixScrollDirection") {
        self.defaults = defaults
        self.key = key
        shared.initialize(to: TapState(systemScrollsNaturally: 0, tap: nil, reArms: 0))
    }

    deinit {
        // Nothing may call back into a half-dead object.
        onStatusChange = nil
        stop()
        shared.deinitialize(count: 1)
        shared.deallocate()
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
        guard ScrollPermission.isGranted else { return settle(.needsPermission) }

        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: Self.callback,
                                           userInfo: UnsafeMutableRawPointer(shared))
        else {
            return settle(.blocked("macOS refused Taurine an event tap, even though Accessibility "
                                 + "permission is granted. Quitting and reopening Taurine usually clears this."))
        }

        let natural = SystemScrollDirection.isNatural
        shared.pointee.systemScrollsNaturally = natural ? 1 : 0
        shared.pointee.tap = Unmanaged.passUnretained(port).toOpaque()
        tap = port

        // The thread publishes its run loop before the semaphore is signalled,
        // which is also the ordering that makes `tapRunLoop` safe to read here.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                ready.signal()
                return
            }
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            self?.tapRunLoop = loop
            ready.signal()

            // Returns when `stop()` stops this run loop, and not before.
            CFRunLoopRun()

            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFMachPortInvalidate(port)
        }
        thread.name = "io.github.john-athan.taurine.scroll"
        // Every scroll on the machine now waits on this thread. Anything less
        // than user-interactive invites the timeout that switches the tap off.
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        guard tapRunLoop != nil else {
            disarmTap()
            return settle(.blocked("Taurine could not attach its scroll tap to a run loop."))
        }
        tapThread = thread
        return settle(.correcting(reversedClass(whenNatural: natural)))
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
    private func disarmTap() {
        // Switch the tap off first, so "off" is true the instant it is asked
        // for rather than whenever the tap thread next gets scheduled.
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false) }
        if let loop = tapRunLoop { CFRunLoopStop(loop) }
        tap = nil
        tapThread = nil
        tapRunLoop = nil
        shared.pointee.tap = nil
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
        guard ScrollPermission.isGranted else {
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
        ScrollPermission.request()
        refresh()
    }

    /// Re-read the global setting and hand the new answer to the tap thread.
    private func reloadSystemDirection() {
        let natural = SystemScrollDirection.isNatural
        shared.pointee.systemScrollsNaturally = natural ? 1 : 0
        if tap != nil { settle(.correcting(reversedClass(whenNatural: natural))) }
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
        case .needsPermission:   return ScrollPermission.missingGrantExplanation
        case .blocked(let why):  return why
        }
    }

    /// How many times macOS has disabled the tap and we have re-armed it. Zero
    /// on a healthy machine; a climbing number means something is stalling the
    /// tap thread and is worth seeing.
    var reArmCount: Int { Int(shared.pointee.reArms) }

    private var reArmNote: String {
        reArmCount == 0 ? "" : "\nRe-armed \(reArmCount) time(s) after macOS switched the tap off."
    }
}
