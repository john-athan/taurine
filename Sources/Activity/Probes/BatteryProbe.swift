import Foundation
import IOKit
import IOKit.ps

/// The plug. 🔌
///
/// The one probe that looks outward. Every other tile measures what the chip is
/// doing; this one measures what the wall is giving and what the cell is taking,
/// which is the question people ask of a laptop and the one the power tile
/// cannot answer: the energy counters behind that tile describe the package, and
/// a Mac charging at twenty watts while the package draws seven is not doing
/// anything the package can see.
///
/// The gauge is `AppleSmartBattery` in the IO registry. It publishes a level
/// rather than a counter, so this probe has no baseline to take in `open()`, and
/// it publishes the two halves of the product separately: `Amperage` in
/// milliamps, signed, and `Voltage` in millivolts. Their product is the flow,
/// and its sign is the direction. `coconutBattery` and `System Information` read
/// the same pair.
///
/// Three decisions worth stating.
///
///   • **A Mac with no battery is not a Mac with a broken battery.** A Mac mini
///     has nothing here to read and nothing wrong with it, so this probe opens
///     successfully, writes nothing, and the panel is one tile shorter. It fails
///     loudly only when the power sources say there is an internal battery and
///     the registry then refuses to describe it, which is a real fault and worth
///     naming in the footer.
///
///   • **The sign is read as a bit pattern, not as a number.** The gauge stores
///     its currents in a sixty-four bit field, and a discharging Mac puts a
///     negative number in it; some of those come back through Core Foundation as
///     the unsigned pattern rather than as the negative it was. Reading every
///     value through `signed` turns both spellings into the same integer, which
///     is what stops a discharging Mac from appearing to charge at eighteen
///     quintillion watts.
///
///   • **`PowerTelemetryData` is checked before it is believed.** It is where
///     the wall figure lives and it is entirely undocumented, so it is required
///     to agree with itself (what comes in is what the machine uses plus what
///     the battery takes) and with the current and voltage the gauge publishes
///     separately. When it does not, the panel shows the adapter's rating alone
///     rather than a number nobody can check.
final class BatteryProbe: ActivityProbe {

    let name = "battery"

    enum Failure: Error, CustomStringConvertible {
        case gaugeMissing
        case propertiesRefused(kern_return_t)

        var description: String {
            switch self {
            case .gaugeMissing:
                return "This Mac reports an internal battery, but no AppleSmartBattery service answered."
            case .propertiesRefused(let code):
                return "The battery gauge would not describe itself (\(code))."
            }
        }
    }

    /// Registry property names, spelled out because that is how they exist:
    /// `AppleSmartBattery` has no public header, and these strings are what
    /// `ioreg -c AppleSmartBattery` prints on every Mac that has one.
    private enum Key {
        static let service = "AppleSmartBattery"
        static let charge = "CurrentCapacity"
        static let capacity = "MaxCapacity"
        static let plugged = "ExternalConnected"
        static let charging = "IsCharging"
        static let full = "FullyCharged"
        static let amperage = "Amperage"
        static let voltage = "Voltage"
        static let toFull = "AvgTimeToFull"
        static let toEmpty = "AvgTimeToEmpty"

        static let adapter = "AdapterDetails"
        static let adapterWatts = "Watts"

        static let telemetry = "PowerTelemetryData"
        static let powerIn = "SystemPowerIn"
        static let load = "SystemLoad"
        static let batteryPower = "BatteryPower"
    }

    /// The gauge's way of saying "ask me again in a minute". A full unsigned
    /// sixteen bit word, in a field of minutes, which is seven weeks: it is a
    /// sentinel rather than an estimate, and a Mac that has just been plugged in
    /// publishes it for a few seconds while the gauge settles.
    static let unknownMinutes: Int64 = 65535

    /// Nothing on a Mac charges or discharges faster than this. A ceiling
    /// rather than a range, and it exists to catch a misread field rather than
    /// to second-guess the hardware: the largest adapter Apple sells is 240 W.
    static let plausibleWatts: Double = 500

    /// Held open for the session. A battery, unlike a USB disk, does not come
    /// and go, so the registry is searched once rather than every second.
    ///
    /// What is fetched every second is the gauge's whole property dictionary,
    /// which is fifty-eight keys and includes several the panel has no use for.
    /// Asking for them individually would be seven round trips instead of one;
    /// measured on an M4 Pro the single fetch costs 0.35 ms, once a second,
    /// only while the panel is open.
    private var gauge: io_service_t = IO_OBJECT_NULL
    private var isOpen = false

    // MARK: - lifecycle

    func open() throws {
        close()
        isOpen = true

        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching(Key.service))
        guard service != IO_OBJECT_NULL else {
            // A desktop. Open, silent, and the panel simply has no battery tile.
            guard Self.machineHasBattery() else { return }
            throw Failure.gaugeMissing
        }
        gauge = service

        var status: kern_return_t = KERN_SUCCESS
        guard Self.properties(of: service, status: &status) != nil else {
            // Give the service back before leaving: the monitor drops a probe
            // that throws without ever calling `close` on it.
            close()
            throw Failure.propertiesRefused(status)
        }
    }

    func close() {
        if gauge != IO_OBJECT_NULL { IOObjectRelease(gauge) }
        gauge = IO_OBJECT_NULL
        isOpen = false
    }

    deinit {
        // The protocol puts the obligation on the probe, and a dropped but
        // unclosed probe would leak one io_object.
        close()
    }

    func read(into sample: inout ActivitySample) {
        guard isOpen, gauge != IO_OBJECT_NULL else { return }
        var status: kern_return_t = KERN_SUCCESS
        guard let properties = Self.properties(of: gauge, status: &status) else { return }
        sample.battery = Self.activity(from: properties)
    }

    // MARK: - the registry

    /// Whether this Mac has an internal battery at all, asked of the power
    /// sources rather than of the registry.
    ///
    /// This is the question that separates "a Mac mini" from "a MacBook whose
    /// gauge did not answer", and it has to be asked somewhere other than the
    /// place that just failed to answer it.
    static func machineHasBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let type = description[kIOPSTypeKey] as? String else { continue }
            if type == kIOPSInternalBatteryType { return true }
        }
        return false
    }

    static func properties(of service: io_service_t,
                           status: inout kern_return_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        status = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard status == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return dictionary
    }

    // MARK: - the arithmetic

    // Everything below this line is a function of a dictionary, so all of it is
    // checked in `Tests/ActivityBatteryTests.swift` against captured readings
    // rather than against whatever this machine happens to be doing.

    /// One reading, or nil when the gauge does not say how full it is, which is
    /// the one field the tile cannot be drawn without.
    static func activity(from properties: [String: Any]) -> BatteryActivity? {
        guard let charge = charge(from: properties) else { return nil }

        let plugged = properties[Key.plugged] as? Bool ?? false
        let charging = properties[Key.charging] as? Bool ?? false
        let flow = batteryWatts(from: properties)

        return BatteryActivity(
            charge: charge,
            isPluggedIn: plugged,
            isCharging: charging,
            isFullyCharged: properties[Key.full] as? Bool ?? false,
            batteryWatts: flow,
            adapterWatts: adapterWatts(from: properties),
            inputWatts: inputWatts(from: properties, batteryWatts: flow),
            // Only ever one of the two, and it is the gauge that decides which:
            // the estimate that is not being made is published as a sentinel,
            // and `minutes` turns that into the nil it means.
            timeToFull: charging ? minutes(properties[Key.toFull]) : nil,
            timeToEmpty: plugged ? nil : minutes(properties[Key.toEmpty]))
    }

    /// State of charge, from whichever pair of units this Mac counts in.
    ///
    /// Apple Silicon publishes a percentage against a maximum of 100; Intel
    /// Macs publish milliamp hours against the pack's full charge. The ratio is
    /// the answer in both cases, which is why the two numbers are divided
    /// rather than either one read as a percentage.
    static func charge(from properties: [String: Any]) -> Double? {
        guard let now = signed(properties[Key.charge]),
              let full = signed(properties[Key.capacity]), full > 0, now >= 0 else { return nil }
        return min(1, Double(now) / Double(full))
    }

    /// Watts into the cell, negative when they are coming out of it.
    static func batteryWatts(from properties: [String: Any]) -> Double? {
        guard let milliamps = signed(properties[Key.amperage]),
              let millivolts = signed(properties[Key.voltage]) else { return nil }
        return watts(milliamps: milliamps, millivolts: millivolts)
    }

    /// The product, in watts, or nil when one of its halves is not a reading.
    ///
    /// A pack voltage of zero is a gauge that has not answered yet rather than
    /// a battery at rest, and the product of it is a confident 0.0 W. Refusing
    /// it here rather than at the caller is what makes that true of every
    /// caller.
    static func watts(milliamps: Int64, millivolts: Int64) -> Double? {
        guard millivolts > 0 else { return nil }
        let product = Double(milliamps) * Double(millivolts) / 1_000_000
        guard product.isFinite, abs(product) <= plausibleWatts else { return nil }
        return product
    }

    static func adapterWatts(from properties: [String: Any]) -> Double? {
        guard let details = properties[Key.adapter] as? [String: Any],
              let rating = signed(details[Key.adapterWatts]),
              rating > 0, Double(rating) <= plausibleWatts else { return nil }
        return Double(rating)
    }

    /// What is coming in through the adapter, in watts, when the machine's own
    /// telemetry is self-consistent.
    ///
    /// `PowerTelemetryData` is undocumented, so it is not taken on its say so.
    /// It publishes three milliwatt figures that have to add up: what comes in
    /// from the adapter is what the machine is using plus what is going into the
    /// battery. It is required to satisfy that identity, and its battery figure
    /// is required to agree with the current and voltage the gauge publishes
    /// separately, which is an independent measurement of the same thing. Either
    /// check failing returns nil, and the tile falls back to the adapter's
    /// rating: a number that cannot be corroborated is not shown at all.
    static func inputWatts(from properties: [String: Any], batteryWatts: Double?) -> Double? {
        guard let telemetry = properties[Key.telemetry] as? [String: Any],
              let incomingMilliwatts = signed(telemetry[Key.powerIn]),
              let loadMilliwatts = signed(telemetry[Key.load]),
              let batteryMilliwatts = signed(telemetry[Key.batteryPower]) else { return nil }

        let incoming = Double(incomingMilliwatts) / 1000
        let load = Double(loadMilliwatts) / 1000
        let intoBattery = Double(batteryMilliwatts) / 1000
        guard incoming > 0, incoming <= plausibleWatts else { return nil }

        // Half a watt, or five percent on a big draw. The three figures are
        // sampled by the power controller at moments of its own choosing, so
        // they agree closely rather than exactly.
        let slack = max(0.5, incoming * 0.05)
        guard abs(incoming - (load + intoBattery)) <= slack else { return nil }

        if let batteryWatts,
           abs(intoBattery - batteryWatts) > max(1, abs(batteryWatts) * 0.2) { return nil }
        return incoming
    }

    /// A gauge estimate in minutes, as seconds, or nil when it is not an
    /// estimate: the sentinel, a zero, or a span longer than any battery lasts.
    static func minutes(_ value: Any?) -> TimeInterval? {
        guard let raw = signed(value), raw > 0, raw != unknownMinutes,
              raw < 60 * 48 else { return nil }
        return TimeInterval(raw) * 60
    }

    /// A registry number as the signed quantity it is.
    ///
    /// Reading `intValue` would be enough for the fields that arrive as signed
    /// integers and wrong for the ones that arrive as the unsigned pattern of a
    /// negative: `-1731` milliamps spelled that way is 1.8e19, which passes
    /// every plausibility check that is looking for a number rather than for a
    /// sign. Taking the sixty-four bit pattern and reinterpreting it handles
    /// both spellings, and can only misread a genuine value above nine
    /// quintillion, which no field here holds.
    static func signed(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        return Int64(bitPattern: number.uint64Value)
    }
}
