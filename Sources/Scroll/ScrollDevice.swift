import CoreGraphics

/// The tell. 🖐️
///
/// Every scroll event carries the evidence of what produced it, so Taurine never
/// asks *which device is this* (a question that needs a vendor table, goes stale
/// with every new mouse, and is unanswerable for a Bluetooth device that has not
/// announced itself yet). It asks *what shape is this event*, which is the same
/// question one layer down and has a stable answer.
///
/// A trackpad and a Magic Mouse report a continuous surface: pixel-precise
/// deltas, a phase that opens and closes around the gesture, and a momentum tail
/// after your fingers leave. A wheel mouse reports discrete clicks: a line count
/// and nothing else.
///
/// The trap: `kCGScrollWheelEventIsContinuous` alone looks sufficient, and on
/// observed hardware it is, but the momentum tail is the part of a gesture where
/// a misclassification is most visible (the page would reverse the instant you
/// let go). So phase and momentum phase are treated as independent evidence of a
/// continuous device rather than as decoration on the continuity flag. Any one of
/// the three is enough.
enum ScrollDevice: Equatable {

    /// A trackpad, a Magic Mouse, or anything else that reports a touch surface.
    case continuousSurface

    /// A wheel mouse: discrete line clicks, no phase, no momentum.
    case wheel

    /// What this class of device is supposed to feel like, per ADR 0004:
    /// content follows your fingers on a surface, the wheel pushes the page.
    var prefersNaturalDirection: Bool { self == .continuousSurface }

    /// The classification. Pure, total, and the only place the rule lives.
    static func classify(_ traits: ScrollTraits) -> ScrollDevice {
        (traits.isContinuous || traits.phase != 0 || traits.momentumPhase != 0)
            ? .continuousSurface : .wheel
    }
}

/// The three numbers the classifier is allowed to look at.
///
/// Split out from `CGEvent` so the decision can be tested over shapes this Mac
/// has no hardware for, and so the tap callback reads exactly three fields and
/// no more.
struct ScrollTraits: Equatable {

    /// `kCGScrollWheelEventIsContinuous`: pixel-based rather than line-based.
    let isContinuous: Bool

    /// `kCGScrollWheelEventScrollPhase`. CoreGraphics defines five values:
    /// 1 began, 2 changed, 4 ended, 8 cancelled, 128 may-begin (fingers
    /// resting). All but cancelled have been observed on an Apple trackpad
    /// here; cancelled is listed because it is a phase the classifier must
    /// treat as a gesture, not because it was seen. 0 means the event is not
    /// part of a gesture, which includes every momentum event.
    let phase: Int64

    /// `kCGScrollWheelEventMomentumPhase`: 1 begin, 2 continue, 3 end. Non-zero
    /// only on the inertial tail of a surface gesture, where `phase` is 0.
    let momentumPhase: Int64

    init(isContinuous: Bool, phase: Int64, momentumPhase: Int64) {
        self.isContinuous = isContinuous
        self.phase = phase
        self.momentumPhase = momentumPhase
    }

    /// Read off a live event. Three field reads, no allocation, no ARC traffic
    /// and no lazy-global check: this runs on the tap thread for every scroll
    /// event the machine produces.
    ///
    /// A static function rather than an `init(of:)` on purpose. Swift passes an
    /// initializer's argument owned, so the initializer form compiled to a
    /// retain in the caller and a release here, once per event. A function
    /// parameter is passed guaranteed, and the pair goes away. Verified by
    /// disassembling the optimised binary, not assumed.
    static func read(_ event: CGEvent) -> ScrollTraits {
        ScrollTraits(isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                     phase: event.getIntegerValueField(scrollPhase),
                     momentumPhase: event.getIntegerValueField(momentumPhase))
    }

    /// `kCGScrollWheelEventScrollPhase`, which CoreGraphics declares in
    /// CGEventTypes.h but does not surface in Swift's `CGEventField`.
    ///
    /// Computed rather than `static let`, because a `static let` is a lazy
    /// global: every read of it carries a one-time-initialisation check, and
    /// two of those were sitting in the per-event path. As a computed property
    /// the optimiser folds it to the constant it is.
    static var scrollPhase: CGEventField { CGEventField(rawValue: 99)! }

    /// `kCGScrollWheelEventMomentumPhase`, likewise.
    static var momentumPhase: CGEventField { CGEventField(rawValue: 123)! }
}
