import CoreGraphics
import Foundation

/// The scroll fix's half of the tap. ↕️🧵
///
/// `EventTap` owns the thread, the port, the re-arming and the teardown, all of
/// which are the same for every fix that has to change an event. What is left
/// here is the part that is only true of scrolling: which events to ask for, one
/// cached answer the callback needs, and the callback itself.
///
/// The cell is a plain struct behind a raw pointer, and it is allocated here and
/// freed here, because the tap may not allocate, retain or lock on the hot path.
/// Freeing it is only safe once no tap thread can still read it, which is why
/// `deinit` stops the tap first and why `stop()` joins the thread rather than
/// merely asking it to leave. See `EventTap` for what that ordering is protecting
/// against, and for the measurements behind it.
final class ScrollTap {

    /// Mirrors `EventTap.Arming`, so the fixer can tell the two failures apart
    /// without knowing that a shared type exists.
    enum Arming {
        case armed(ScrollTap)

        /// `CGEvent.tapCreate` refused, with Accessibility already granted.
        case refused

        /// The port exists but could not be put on a run loop.
        case noRunLoop
    }

    /// The one thing the callback needs and cannot work out for itself.
    private struct State {

        /// 1 when `com.apple.swipescrolldirection` is on. Written by the main
        /// thread, read once per scroll event. An aligned 32-bit scalar cannot
        /// tear, and the worst outcome of the race is that one event on the
        /// boundary of changing the setting uses the previous answer.
        var systemScrollsNaturally: Int32
    }

    private let state: UnsafeMutablePointer<State>
    private let tap: EventTap

    /// Classify one scroll event and flip it if the policy says so. Three field
    /// reads, one comparison, and in the flipped case six reads and six writes.
    /// No allocation, no locks, no calls out of the process.
    private static let handler: EventTap.Handler = { event, user in
        let state = user.assumingMemoryBound(to: State.self)
        ScrollCorrection.apply(to: event,
                               systemScrollsNaturally: state.pointee.systemScrollsNaturally != 0)
    }

    /// Create the tap and come back only once it is live or known not to be.
    static func arm(systemScrollsNaturally natural: Bool) -> Arming {
        let state = UnsafeMutablePointer<State>.allocate(capacity: 1)
        state.initialize(to: State(systemScrollsNaturally: natural ? 1 : 0))

        // Both failures come back with no tap and no thread, so the cell can be
        // freed right here; only the armed case hands it to a `ScrollTap`.
        switch EventTap.arm(name: "io.github.john-athan.taurine.scroll",
                            eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                            user: UnsafeMutableRawPointer(state),
                            handler: handler) {
        case .armed(let tap):
            return .armed(ScrollTap(state: state, tap: tap))
        case .refused:
            state.deinitialize(count: 1)
            state.deallocate()
            return .refused
        case .noRunLoop:
            state.deinitialize(count: 1)
            state.deallocate()
            return .noRunLoop
        }
    }

    private init(state: UnsafeMutablePointer<State>, tap: EventTap) {
        self.state = state
        self.tap = tap
    }

    /// Take the tap down, and do not come back until its thread has gone.
    /// Idempotent, and safe on a tap whose run loop never came up.
    func stop() { tap.stop() }

    deinit {
        // The order is the whole safety property: no tap thread exists past the
        // first line, so nothing can read the cell the second line frees.
        tap.stop()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    /// Hand the tap thread a new answer for the global setting.
    func setSystemScrollsNaturally(_ natural: Bool) {
        state.pointee.systemScrollsNaturally = natural ? 1 : 0
    }

    /// How many times macOS has disabled this tap and the callback has brought
    /// it back. Taking the tap down is not one of them.
    var reArmCount: Int { tap.reArmCount }
}
