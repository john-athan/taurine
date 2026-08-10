import CoreGraphics
import Foundation

/// The tap, its thread, and the one cell they share. 🧵
///
/// Every fix on the "things Apple got wrong" shelf that has to change an event
/// before an application sees it comes through here. The callback is a C
/// function on a thread of its own, and it reads a plain heap cell handed to it
/// as `userInfo`. That much is forced: the callback sits in front of every event
/// of its kind on the machine, and a callback that is slow to answer is not
/// slowed down, it is switched off. So it may not retain, release, allocate or
/// lock.
///
/// What is not forced is who owns the cell, and that is the reason this type
/// exists rather than three loose properties on each feature.
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
///
/// **The feature's own cell is not owned here.** A tap holds the pointer it was
/// given and hands it to the handler; the feature allocates it and frees it. The
/// same rule applies to it as to this one, and it is kept the same way: a
/// feature frees its cell only after `stop()` has returned, or after the last
/// reference to its tap has gone, which joins the thread on the way out.
///
/// **A tap never deletes an event.** The handler is handed a live event and may
/// rewrite its fields; the event then continues on its way whatever the handler
/// did. Swallowing is not offered, because a bug in a tap that can swallow is a
/// keyboard or a trackpad that has stopped working with no way to tell why.
final class EventTap {

    /// The result of trying to arm a tap. An enum rather than an optional
    /// because the two failures are different situations and the menu says
    /// different things about them.
    ///
    /// On both failures no tap exists by the time `arm` returns and no thread is
    /// left running, so the caller may free the cell it passed in immediately.
    enum Arming {
        case armed(EventTap)

        /// `CGEvent.tapCreate` refused, with Accessibility already granted.
        case refused

        /// The port exists but could not be put on a run loop.
        case noRunLoop
    }

    /// What a feature is given for every event: the event itself, and the
    /// pointer to its own cell that it handed to `arm`. A C function pointer, so
    /// it may not capture anything, which is the point: a capture would be a
    /// Swift object the tap thread could touch.
    typealias Handler = @convention(c) (CGEvent, UnsafeMutableRawPointer) -> Void

    /// The only memory the two threads share. Deliberately a plain struct behind
    /// a raw pointer: the callback must not retain, release, or allocate.
    private struct Cell {

        /// The tap itself, unretained, so the callback can re-arm it without
        /// touching ARC. `EventTap` holds the strong reference. Emptied on the
        /// tap thread as the first act of teardown, which is what stops the
        /// teardown from re-arming the very tap it is removing.
        var port: UnsafeMutableRawPointer?

        /// How many times macOS has disabled us and the callback has brought us
        /// back. Written by the tap thread, read by the menu for diagnostics.
        var reArms: Int32

        /// The feature's cell, passed straight back to it. Never dereferenced
        /// here, never freed here.
        var user: UnsafeMutableRawPointer

        var handler: Handler
    }

    /// What the tap thread and its owner pass between them.
    ///
    /// A separate object so the thread body captures no `EventTap`. A strong
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

    private let cell: UnsafeMutablePointer<Cell>
    private let port: CFMachPort
    private let handoff: Handoff

    /// False once `stop` has run, so stopping twice is quiet and `deinit` after
    /// an explicit `stop` does not wait on a semaphore nobody will signal.
    private var isRunning = true

    /// The whole hot path: two comparisons, two field reads and one indirect
    /// call, with no allocation, no lock, and no call into any Swift object or
    /// the main thread.
    ///
    /// The two comparisons and the indirect call are what generalising this cost
    /// the scroll fix, which used to test for its own event type first and
    /// inline its work here. They buy one copy of a teardown whose ordering was
    /// arrived at by measurement, instead of one copy per feature.
    ///
    /// The ARC accounting, read off the optimised binary rather than assumed:
    /// none of this does any. One retain/release pair remains and it is not
    /// removable, because `CGEventTapCallBack` declares its event parameter as a
    /// managed `CGEvent`, so the compiler's `@convention(c)` thunk retains on the
    /// way in and releases on the way out, once per event, outside this closure.
    /// The re-arm branch adds a second pair of its own, and it runs about as
    /// often as macOS switches us off.
    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let cell = info.assumingMemoryBound(to: Cell.self)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The two types the system uses to tell us it has switched us off:
            // `.tapDisabledByTimeout` when a callback took too long,
            // `.tapDisabledByUserInput` under a secure-input or debugger
            // condition. Both are recoverable by simply enabling the same port
            // again, on this thread, right now.
            //
            // An empty port means teardown got here first, so there is nothing
            // to come back to and, just as importantly, nothing to count.
            if let port = cell.pointee.port {
                CGEvent.tapEnable(tap: Unmanaged<CFMachPort>.fromOpaque(port).takeUnretainedValue(),
                                  enable: true)
                cell.pointee.reArms &+= 1
            }
        } else {
            cell.pointee.handler(event, cell.pointee.user)
        }
        return Unmanaged.passUnretained(event)
    }

    /// Create the tap, put it on a run loop on a thread of its own, and come
    /// back only once it is live or known not to be.
    ///
    /// `name` names the thread, which is how the tests find it: a tap's thread is
    /// the only outward sign that the tap exists.
    static func arm(name: String,
                    eventsOfInterest mask: CGEventMask,
                    user: UnsafeMutableRawPointer,
                    handler: @escaping Handler) -> Arming {
        let cell = UnsafeMutablePointer<Cell>.allocate(capacity: 1)
        cell.initialize(to: Cell(port: nil, reArms: 0, user: user, handler: handler))

        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: callback,
                                           userInfo: UnsafeMutableRawPointer(cell))
        else {
            // No thread has been started, so this is the one failure that may
            // free the cell itself. Every later one hands it to an `EventTap`.
            cell.deinitialize(count: 1)
            cell.deallocate()
            return .refused
        }
        cell.pointee.port = Unmanaged.passUnretained(port).toOpaque()

        let tap = EventTap(cell: cell, port: port, name: name)
        guard tap.handoff.runLoop != nil else {
            // `tap` owns the thread, the port and the cell by now, so the
            // cleanup is simply letting it go: `deinit` joins the thread,
            // invalidates the port and frees the cell, in that order, before
            // this function returns.
            return .noRunLoop
        }
        return .armed(tap)
    }

    private init(cell: UnsafeMutablePointer<Cell>, port: CFMachPort, name: String) {
        self.cell = cell
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
        thread.name = name
        // Every event of this kind on the machine now waits on this thread.
        // Anything less than user-interactive invites the timeout that switches
        // the tap off.
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
            let cell = self.cell
            let port = self.port
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                cell.pointee.port = nil
                CGEvent.tapEnable(tap: port, enable: false)
                CFRunLoopStop(loop)
            }
            CFRunLoopWakeUp(loop)
        }

        // The join is the point of the whole type. Past this line no tap thread
        // exists, so nothing can read either cell and nothing can use the port.
        handoff.didExit.wait()
        CFMachPortInvalidate(port)
    }

    deinit {
        stop()
        cell.deinitialize(count: 1)
        cell.deallocate()
    }

    /// How many times macOS has disabled this tap and the callback has brought
    /// it back. Taking the tap down is not one of them.
    var reArmCount: Int { Int(cell.pointee.reArms) }
}
