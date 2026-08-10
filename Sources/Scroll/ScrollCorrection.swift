import Foundation
import CoreGraphics

/// The verdict. ↕️
///
/// macOS has already applied `com.apple.swipescrolldirection` by the time an
/// event reaches a session tap, and it applied it to every device the same way.
/// So this is not a second direction setting; it is a correction on top of the
/// one the system made. Exactly one class of device is ever wrong, and it is
/// always the class that disagrees with the global flag:
///
///     system says natural   →  surfaces are right, wheels are flipped
///     system says traditional →  wheels are right, surfaces are flipped
///
/// Which collapses to one comparison, `device.prefersNaturalDirection != natural`,
/// and that is the whole policy. Turning the system setting off does not turn
/// Taurine off, it moves the correction to the other class, so somebody who likes
/// the traditional feel on a trackpad gets the mirror image of this feature for
/// free.
///
/// The trap is in `negateDeltas`, not here. See the comment there before touching
/// the order of the writes.
enum ScrollCorrection {

    /// The policy. Pure, exhaustive over a two-by-two matrix, and tested as such.
    static func mustNegate(_ device: ScrollDevice, systemScrollsNaturally natural: Bool) -> Bool {
        device.prefersNaturalDirection != natural
    }

    /// Classify one event and flip it if the policy says so. This is everything
    /// the tap callback does: three field reads, one comparison, and in the
    /// flipped case six reads and six writes. No allocation, no locks, no calls
    /// out of the process.
    static func apply(to event: CGEvent, systemScrollsNaturally natural: Bool) {
        let device = ScrollDevice.classify(ScrollTraits.read(event))
        guard mustNegate(device, systemScrollsNaturally: natural) else { return }
        negateDeltas(of: event)
    }

    /// Reverse both axes of a scroll event, in every unit the event carries.
    ///
    /// An event carries the same scroll in three currencies: line deltas
    /// (`DeltaAxis`), fixed-point 16.16 deltas (`FixedPtDeltaAxis`) and pixel
    /// deltas (`PointDeltaAxis`). Different readers take different ones, and the
    /// mapping is measurable rather than a matter of opinion: `NSEvent.deltaY` is
    /// always the fixed-point field, `NSEvent.scrollingDeltaY` is the pixel field
    /// on a continuous event and the fixed-point field otherwise, and the line
    /// field is what older, non-AppKit readers take. Flip a subset and the scroll
    /// fights itself: the page moves one way and its scrollbar the other, or a
    /// momentum tail reverses halfway.
    ///
    /// The trap, verified by experiment on macOS 26: writing `DeltaAxisN`
    /// **rewrites the other two fields on that axis**. CoreGraphics recomputes
    /// the fixed-point value to match and multiplies the line value out into a
    /// new pixel value. Two consequences, both silent:
    ///
    ///   * Every field must be read before any field is written.
    ///   * The line delta must be written *first*, so that the fixed-point and
    ///     pixel writes that follow put back the precision it destroyed.
    ///
    /// The worst case is not a rounding error. Most of a slow trackpad drag
    /// arrives as pixel-only events with a line delta of zero, so writing the
    /// line delta last (or writing only it) sets the pixel delta to zero times
    /// something and the gesture stops moving the page at all.
    ///
    /// Axis 3 is documented as unused and is left alone. The accelerated and raw
    /// delta fields are the system's own inputs to the numbers above, not what
    /// applications read, so they are left alone too.
    static func negateDeltas(of event: CGEvent) {
        let line1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let line2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let fixed1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixed2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let point1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let point2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)

        // Wrapping negation: a scroll delta is never near Int64.min, and a trap
        // on the tap thread would take the user's scrolling down with it.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0 &- line1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0 &- line2)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixed2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0 &- point1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0 &- point2)
    }
}

/// The other half of the rule, the half macOS owns.
///
/// `com.apple.swipescrolldirection` lives in the global preferences domain, is
/// absent until somebody changes it, and defaults to natural. Reading it costs a
/// round trip to `cfprefsd`, which is nothing once per change and far too much
/// per scroll event, so the fixer reads it here and caches the answer.
enum SystemScrollDirection {

    /// The key, in `NSGlobalDomain`.
    static let key = "com.apple.swipescrolldirection" as CFString

    /// Posted by the system when the checkbox moves in System Settings. This is
    /// how a change reaches Taurine with no polling and no timer.
    static let changeNotification = Notification.Name("SwipeScrollDirectionDidChangeNotification")

    /// True when the system is currently scrolling naturally.
    static var isNatural: Bool {
        // cfprefsd caches another process's writes, and this value is only ever
        // written by another process, so the cache has to be dropped before the
        // read or a change in System Settings can go unnoticed indefinitely.
        //
        // Every caller is an event: the change notification, an app activation,
        // or a menu about to open. None of them is a loop and none of them is
        // per-scroll-event, so a round trip to cfprefsd here is affordable. The
        // tap thread never calls this; it reads the cached Int32.
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return interpret(CFPreferencesCopyAppValue(key, kCFPreferencesAnyApplication))
    }

    /// Split out from the read so the awkward values can be tested.
    ///
    /// The preference is a boolean when System Settings writes it, but
    /// `defaults write -g com.apple.swipescrolldirection -int 0` is a thing
    /// people do, and `-string` is a thing people do by accident. Anything
    /// unreadable falls back to natural, which is what a Mac ships with, so the
    /// fallback matches the machine rather than being an arbitrary default.
    static func interpret(_ value: CFPropertyList?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return (string as NSString).boolValue }
        return true
    }
}
