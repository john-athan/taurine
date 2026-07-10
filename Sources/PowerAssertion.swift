import Foundation
import IOKit.pwr_mgt

/// The molecule. 🧪
///
/// Everything Taurine does ultimately comes down to one primitive: an IOKit
/// *power assertion*. An assertion is a passive flag you hand the kernel that
/// says "please don't sleep." It costs nothing to hold — no timer, no polling,
/// no CPU. When you let go (or your process dies), the kernel forgets it.
///
/// `caffeinate -d` is literally this, wrapped in a CLI. We wrap it in a bull.
struct SleepGuard: OptionSet {
    let rawValue: Int
    /// Keep the *display* awake (this is `caffeinate -d`).
    static let display = SleepGuard(rawValue: 1 << 0)
    /// Keep the *whole machine* awake even if the screen is off (`caffeinate -i`).
    static let system  = SleepGuard(rawValue: 1 << 1)

    /// The IOKit assertion type string for each guard we hold.
    var assertionTypes: [String] {
        var t: [String] = []
        if contains(.display) { t.append(kIOPMAssertionTypePreventUserIdleDisplaySleep) }
        if contains(.system)  { t.append(kIOPMAssertionTypePreventUserIdleSystemSleep) }
        return t
    }
}

/// Holds one or more kernel assertions and, crucially, remembers *why*.
/// The "why" is the whole point of Taurine — a reason you can read, and that
/// can end on its own.
final class PowerAssertion {
    private(set) var isHeld = false
    private(set) var reason = ""
    private(set) var guards: SleepGuard = []
    private var ids: [IOPMAssertionID] = []

    /// Grab the kernel by the horns. Idempotent-ish: re-holding replaces the old grip.
    func hold(_ guards: SleepGuard, reason: String) {
        release()
        var acquired: [IOPMAssertionID] = []
        for type in guards.assertionTypes {
            var id: IOPMAssertionID = 0
            let ok = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Taurine — \(reason)" as CFString,
                &id)
            if ok == kIOReturnSuccess { acquired.append(id) }
        }
        ids = acquired
        isHeld = !acquired.isEmpty
        self.guards = guards
        self.reason = reason
    }

    /// Let go. The kernel would do this for us if we crashed, but we're polite.
    func release() {
        for id in ids { IOPMAssertionRelease(id) }
        ids = []
        isHeld = false
        reason = ""
        guards = []
    }

    deinit { release() }
}
