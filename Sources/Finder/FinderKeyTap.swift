import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// The Finder fix's half of the tap, and the bookkeeping of a pending cut. ✂️🧵
///
/// `EventTap` owns the thread, the port, the re-arming and the teardown. What is
/// here is what is only true of this feature: which keys can possibly matter,
/// the three numbers that say whether a cut is still pending, and the callback
/// that puts them together.
///
/// **This tap only exists while Finder is the front application.** That is not a
/// nicety, it is the design: a keyboard tap that is always armed sees every
/// keystroke on the machine, and Taurine has no business seeing those.
/// `FinderCutPaste` arms this when Finder comes forward and takes it down when
/// anything else does, driven by the workspace notification that was already
/// being observed for the scroll fix. See ADR 6 for what that does and does not
/// promise.
///
/// **What the callback reads.** For every key-down and key-up in Finder: one
/// integer field, the key code. For all but four keys on the keyboard that is
/// the entire cost and the event is untouched. Nothing is logged, nothing is
/// counted, nothing leaves the process; the tap has no way to send anything
/// anywhere, because Taurine opens no socket.
///
/// **How a pending cut is recognised.** The rule has to distinguish the
/// pasteboard our own ⌘X put there from any other pasteboard, and it has to do
/// it without polling, because a Taurine that polls is a Taurine that shows a
/// timer in its own badge. The pasteboard's change count answers it, sampled at
/// three moments:
///
///   * just before the rewritten ⌘X is let through (`before`),
///   * again as the ⌘X key-up goes by, by which time Finder has copied
///     (`pending`),
///   * once more when ⌘V arrives.
///
/// A cut is still pending exactly when the third sample equals the second, which
/// is false the moment anything else copies anything, in Finder or in any other
/// application. If the second sample equals the first, nothing was selected and
/// Finder copied nothing, so no cut is armed at all and ⌘V stays an ordinary
/// paste. The measured cost of a sample here is 0.9 µs, and it is taken only for
/// the four keys above.
///
/// `awaitingCopy` is the allowance for a Finder that was too busy to have
/// finished copying by the time the key came back up: the cut stays claimable
/// until some copy lands, which the ⌘C rule below then hands over cleanly.
final class FinderKeyTap {

    /// Mirrors `EventTap.Arming`, so the feature can tell the two failures apart
    /// without knowing that a shared type exists.
    enum Arming {
        case armed(FinderKeyTap)
        case refused
        case noRunLoop
    }

    /// The cell the two threads share.
    private struct State {

        /// Finder's Accessibility element, unretained. `FinderKeyTap` holds the
        /// strong reference, and no tap thread outlives it.
        var finder: UnsafeMutableRawPointer

        /// The pending cut. A plain scalar struct, so it can live here without
        /// any reference for the callback to retain or release.
        var cut: PendingCut
    }

    private let state: UnsafeMutablePointer<State>
    private let finder: AXUIElement
    private let tap: EventTap

    // MARK: - the callback

    private static let handler: EventTap.Handler = { event, user in
        let state = user.assumingMemoryBound(to: State.self)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // The filter that keeps this off everybody's keyboard. Four comparisons,
        // no allocation, and for every other key the callback is already done.
        switch keyCode {
        case Int64(kVK_ANSI_X), Int64(kVK_ANSI_C), Int64(kVK_ANSI_V):
            guard event.flags.contains(.maskCommand) else { return }
        case Int64(kVK_Escape):
            guard FinderCutLedger.hasCut(state.pointee.cut) else { return }
        default:
            return
        }

        // Past here we are looking at ⌘X, ⌘C, ⌘V or a cancelling Escape, typed
        // in Finder. Tens of microseconds are affordable; milliseconds are not.
        let key = KeyPress.read(event)
        let editing = keyCode != Int64(kVK_Escape)
            && FinderFocus.isEditingText(Unmanaged<AXUIElement>
                .fromOpaque(state.pointee.finder).takeUnretainedValue())

        // The pasteboard is only asked about when there is a cut to ask about,
        // which is the difference between a question per cut and a question per
        // ⌘C anybody ever types in Finder.
        //
        // The reading is used twice: to pin a claim that was still waiting for
        // its copy, so that every decision after this one is made on an exact
        // count, and then to answer the question that was asked.
        var cut = state.pointee.cut
        var pending = false
        if FinderCutLedger.hasCut(cut) {
            let now = changeCount()
            cut = FinderCutLedger.pin(cut, changeCount: now)
            state.pointee.cut = cut
            pending = FinderCutLedger.isPending(cut, changeCount: now)
        }

        let action = FinderCutPolicy.decide(key, editingText: editing, cutIsPending: pending)
        FinderCutPolicy.apply(action, to: event)
        guard action != .passThrough else { return }

        // Sampled after the rewrite and before Finder has seen the event, which
        // is what makes `before` the count Finder's own copy will move past.
        state.pointee.cut = FinderCutLedger.after(action, isDown: key.isDown,
                                                  cut: cut, changeCount: changeCount())
    }

    /// The general pasteboard's change count, read from the tap thread.
    ///
    /// Measured here at 0.9 µs warm on a background thread, and it does see
    /// another process's writes, which is the property the whole rule rests on.
    private static func changeCount() -> Int64 { Int64(NSPasteboard.general.changeCount) }

    // MARK: - lifecycle

    /// Arm a tap on Finder's keyboard, carrying over whatever cut was pending
    /// when the last one was taken down.
    static func arm(finderPID pid: pid_t, carrying cut: PendingCut) -> Arming {
        let finder = AXUIElementCreateApplication(pid)
        // A wedged Finder must cost one keystroke, not the tap. 50 ms is far
        // beyond a healthy answer (38 µs here) and far inside the timeout that
        // makes macOS switch a tap off.
        AXUIElementSetMessagingTimeout(finder, 0.05)

        let state = UnsafeMutablePointer<State>.allocate(capacity: 1)
        state.initialize(to: State(finder: Unmanaged.passUnretained(finder).toOpaque(), cut: cut))

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
                 | CGEventMask(1 << CGEventType.keyUp.rawValue)

        // Both failures come back with no tap and no thread, so the cell can be
        // freed right here; only the armed case hands it to a `FinderKeyTap`.
        switch EventTap.arm(name: "io.github.john-athan.taurine.finder",
                            eventsOfInterest: mask,
                            user: UnsafeMutableRawPointer(state),
                            handler: handler) {
        case .armed(let tap):
            return .armed(FinderKeyTap(state: state, finder: finder, tap: tap))
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

    private init(state: UnsafeMutablePointer<State>, finder: AXUIElement, tap: EventTap) {
        self.state = state
        self.finder = finder
        self.tap = tap
    }

    /// Take the tap down, and do not come back until its thread has gone.
    func stop() { tap.stop() }

    deinit {
        // The order is the whole safety property: no tap thread exists past the
        // first line, so nothing can read the cell the second line frees, and
        // nothing can reach the Accessibility element the third releases.
        tap.stop()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    /// The pending cut as it stands, so the owner can carry it to the next tap.
    /// Read after `stop()`, where the tap thread is gone and no lock is needed.
    var cut: PendingCut { state.pointee.cut }

    /// How many times macOS has disabled this tap and the callback has brought
    /// it back. Taking the tap down is not one of them.
    var reArmCount: Int { tap.reArmCount }
}
