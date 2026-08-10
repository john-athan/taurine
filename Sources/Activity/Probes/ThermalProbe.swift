import Foundation

/// The thermostat. 🌡️
///
/// The smallest probe in the panel, and the only one whose interest is in what
/// it refuses to do. Every other Mac system monitor shows temperatures, read
/// from SMC keys like `TC0P` that Apple has never documented and that move
/// between chip generations. Taurine already talks to the SMC for the charge
/// limiter (`Sources/Charge/SMC.swift`), so shipping temperatures would cost
/// nothing but a key table, and the key table is precisely the problem: when it
/// is wrong it is not blank, it is a confident number that is off by twenty
/// degrees. ADR 0003 settles this, and this file is where the decision lands.
///
/// `ProcessInfo.thermalState` is public, documented and free. It is not a
/// temperature, it is the answer to the question people are actually asking,
/// which is whether the machine is about to slow down.
///
/// It holds nothing, so `open()` and `close()` are genuinely empty rather than
/// unfinished. The value is maintained by the system and delivered by
/// notification; reading the property is a load from a cached field, not a
/// round trip, which is why this probe has no state to acquire or release.
final class ThermalProbe: ActivityProbe {

    let name = "thermal"

    private var isOpen = false

    func open() throws { isOpen = true }

    func close() { isOpen = false }

    func read(into sample: inout ActivitySample) {
        // A level, so there is no baseline for `open()` to have taken. The flag
        // still exists, because a probe that answers after it has been closed
        // is the odd one out among the seven, and somebody will eventually rely
        // on read-after-close being inert.
        guard isOpen else { return }
        sample.thermal = ThermalActivity(state: ProcessInfo.processInfo.thermalState)
    }
}
