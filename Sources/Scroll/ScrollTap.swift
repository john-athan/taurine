import CoreGraphics
import Foundation

/// The tap, its thread, and the one cell they share. 🧵
///
/// The callback is a C function on a thread of its own, and it reads a plain
/// heap cell handed to it as `userInfo`. That much is forced: the callback sits
/// in front of every scroll event on the machine, and a callback that is slow to
/// answer is not slowed down, it is switched off. So it may not retain, release,
/// allocate or lock.
///
/// What is not forced is who owns the cell, and that is the reason this type
/// exists rather than three loose properties on the fixer.
///
/// Switching a tap off from another thread makes macOS deliver one last
/// callback on the tap thread: measured here on 198 of 200 teardowns. So a
/// teardown that disables the tap, asks the run loop to stop and returns leaves
/// a callback in flight over memory the caller is about to free. Making that
/// window smaller is not a fix. Making the free unreachable is:
///
///   * The cell is allocated in `arm` and freed in `deinit`, nowhere else.
///   * `deinit` cannot reach the free without going through `stop`.
///   * `stop` does not return until the tap thread has left its run loop.
///
/// "The thread is gone" is therefore a precondition of "the memory is gone",
/// written in the control flow instead of asserted in a comment about timing.
///
/// The second trap is that the teardown's own disable callback will happily
/// re-arm the tap it is tearing down, which resurrects a dead tap for an instant
/// and inflates `reArmCount`, a number the menu shows the user as evidence that
/// something is stalling. That is why the teardown is posted to the tap thread
/// instead: stopping the run loop on the same thread that would dispatch the
/// callback means the callback is never dispatched at all, measured as 0 of 200
/// against 198 of 200 for the same teardown driven from outside.
final class ScrollTap {

    /// The result of trying to arm a tap. An enum rather than an optional
    /// because the two failures are different situations and the menu says
    /// different things about them.
    enum Arming {
        case armed(ScrollTap)

        /// `CGEvent.tapCreate` refused, with Accessibility already granted.
        case refused

        /// The port exists but could not be put on a run loop.
        case noRunLoop
    }

    /// The only memory the two threads share. Deliberately a plain struct behind
    /// a raw pointer: the callback must not retain, release, or allocate.
    private struct State {

        /// 1 when `com.apple.swipescrolldirection` is on. Written by the main
        /// thread, read once per scroll event. An aligned 32-bit scalar cannot
        /// tear, and the worst outcome of the race is that one event on the
        /// boundary of changing the setting uses the previous answer.
        var systemScrollsNaturally: Int32

        /// The tap itself, unretained, so the callback can re-arm it without
        /// touching ARC. `ScrollTap` holds the strong reference. Emptied on the
        /// tap thread as the first act of teardown, which is what stops the
        /// teardown from re-arming the very tap it is removing.
        var port: UnsafeMutableRawPointer?

        /// How many times macOS has disabled us and the callback has brought us
        /// back. Written by the tap thread, read by the menu for diagnostics.
        var reArms: Int32
    }

    /// What the tap thread and its owner pass between them.
    ///
    /// A separate object so the thread body captures no `ScrollTap`. A strong
    /// capture there would keep the tap alive for exactly as long as the thread
    /// runs, and since `deinit` is what ends the thread, the two would wait for
    /// each other forever.
    private final class Handoff {
        let ready = DispatchSemaphore(value: 0)
        let didExit = DispatchSemaphore(value: 0)

        /// Written by the tap thread before `ready` is signalled and read by the
        /// owner only after `ready` returns. That ordering is the whole of its
        /// synchronisation, and it is why `stop` may read it without a lock.
        var runLoop: CFRunLoop?
    }

    private let state: UnsafeMutablePointer<State>
    private let port: CFMachPort
    private let handoff: Handoff

    /// False once `stop` has run, so stopping twice is quiet and `deinit` after
    /// an explicit `stop` does not wait on a semaphore nobody will signal.
    private var isRunning = true

    /// The whole hot path. One branch, three field reads and six field writes at
    /// most, no allocation, no lock, and no call into any Swift object or the
    /// main thread.
    ///
    /// The ARC accounting, read off the optimised binary rather than assumed.
    /// The scroll branch does none: `ScrollTraits.read` compiles to three
    /// `CGEventGetIntegerValueField` calls with the field numbers as immediates.
    /// One retain/release pair remains, and it is not removable: `CGEventTapCallBack`
    /// declares its event parameter as a managed `CGEvent`, so the compiler's
    /// `@convention(c)` thunk retains on the way in and releases on the way out,
    /// once per event, outside this closure. The re-arm branch adds a second
    /// pair of its own, and it runs about as often as macOS switches us off.
    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let state = info.assumingMemoryBound(to: State.self)

        if type == .scrollWheel {
            ScrollCorrection.apply(to: event,
                                   systemScrollsNaturally: state.pointee.systemScrollsNaturally != 0)
        } else if let port = state.pointee.port {
            // The only other types we can be sent are the two the system uses to
            // tell us it has switched us off: `.tapDisabledByTimeout` when a
            // callback took too long, `.tapDisabledByUserInput` under a
            // secure-input or debugger condition. Both are recoverable by simply
            // enabling the same port again, on this thread, right now.
            //
            // An empty port means teardown got here first, so there is nothing
            // to come back to and, just as importantly, nothing to count.
            CGEvent.tapEnable(tap: Unmanaged<CFMachPort>.fromOpaque(port).takeUnretainedValue(),
                              enable: true)
            state.pointee.reArms &+= 1
        }
        return Unmanaged.passUnretained(event)
    }

    /// Create the tap, put it on a run loop on a thread of its own, and come
    /// back only once it is live or known not to be.
    static func arm(systemScrollsNaturally natural: Bool) -> Arming {
        let state = UnsafeMutablePointer<State>.allocate(capacity: 1)
        state.initialize(to: State(systemScrollsNaturally: natural ? 1 : 0, port: nil, reArms: 0))

        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: callback,
                                           userInfo: UnsafeMutableRawPointer(state))
        else {
            // No thread has been started, so this is the one failure that may
            // free the cell itself. Every later one hands it to a `ScrollTap`.
            state.deinitialize(count: 1)
            state.deallocate()
            return .refused
        }
        state.pointee.port = Unmanaged.passUnretained(port).toOpaque()

        let tap = ScrollTap(state: state, port: port)
        guard tap.handoff.runLoop != nil else {
            // `tap` owns the thread, the port and the cell by now, so the
            // cleanup is simply letting it go: `deinit` joins the thread,
            // invalidates the port and frees the cell, in that order.
            return .noRunLoop
        }
        return .armed(tap)
    }

    private init(state: UnsafeMutablePointer<State>, port: CFMachPort) {
        self.state = state
        self.port = port
        let handoff = Handoff()
        self.handoff = handoff

        let thread = Thread {
            // Signalled on every path out, so an owner waiting to join is never
            // left waiting on a thread that gave up before it started.
            defer { handoff.didExit.signal() }

            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                handoff.ready.signal()
                return
            }
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            handoff.runLoop = loop
            handoff.ready.signal()

            // Returns when `stop` stops this run loop, and not before.
            CFRunLoopRun()

            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        thread.name = "io.github.john-athan.taurine.scroll"
        // Every scroll on the machine now waits on this thread. Anything less
        // than user-interactive invites the timeout that switches the tap off.
        thread.qualityOfService = .userInteractive
        thread.start()
        handoff.ready.wait()
    }

    /// Take the tap down, and do not come back until its thread has gone.
    /// Idempotent, and safe on a tap whose run loop never came up.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let loop = handoff.runLoop {
            // The disable happens over there rather than here, and the run loop
            // stops immediately after it on the same thread, so the disable
            // callback never reaches the point of being dispatched. Measured: 0
            // of 200 teardowns see it this way, against 198 of 200 when the
            // disable is called from this side instead.
            //
            // Emptying the cell first is the belt to that pair of braces. It
            // costs one store and it is what makes the callback harmless rather
            // than merely unlikely, which matters because "the run loop stops
            // before the source is dispatched" is a property of CoreFoundation's
            // scheduling, not a promise anybody made us.
            let state = self.state
            let port = self.port
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                state.pointee.port = nil
                CGEvent.tapEnable(tap: port, enable: false)
                CFRunLoopStop(loop)
            }
            CFRunLoopWakeUp(loop)
        }

        // The join is the point of the whole type. Past this line no tap thread
        // exists, so nothing can read the cell and nothing can use the port.
        handoff.didExit.wait()
        CFMachPortInvalidate(port)
    }

    deinit {
        stop()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    /// Hand the tap thread a new answer for the global setting.
    func setSystemScrollsNaturally(_ natural: Bool) {
        state.pointee.systemScrollsNaturally = natural ? 1 : 0
    }

    /// How many times macOS has disabled this tap and the callback has brought
    /// it back. Taking the tap down is not one of them.
    var reArmCount: Int { Int(state.pointee.reArms) }
}
