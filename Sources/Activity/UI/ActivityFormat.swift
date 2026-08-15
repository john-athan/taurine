import Foundation

/// The units. 📏
///
/// Every number the panel shows passes through here, so that a watt looks like
/// a watt in the headline and in the VoiceOver sentence, and so that the rules
/// about precision live in one place instead of in nine `String(format:)` calls
/// scattered through the drawing code.
///
/// Two decisions are worth stating, because both look like bugs from the
/// outside:
///
///   • Memory counts in 1024s and traffic counts in 1000s. That is not
///     sloppiness, it is what the two numbers mean. The "24 GB" on the box is
///     24 × 2^30 bytes, and a memory readout that disagreed with the box would
///     be wrong. A disk or a network quotes megabytes per second in millions,
///     and a rate readout that disagreed with every other tool would also be
///     wrong. The unit labels are the conventional ones for each.
///
///   • Precision shrinks as the number grows: one decimal below a hundred, none
///     above, and none at all in the base unit. The point is a number that
///     changes its value every second without changing its width, because a
///     readout whose digits move sideways is unreadable at a glance. The
///     monospaced-digit fonts in `ActivityTheme` are the other half of that.
///
/// The trap: rounding can push a value past the boundary that chose its
/// precision. 999_999 B/s scaled to kB/s is 999.999, which prints with no
/// decimals as "1000 kB/s", a unit nobody uses; 99.95 W printed with one
/// decimal is "100.0 W", two characters wider than the "100 W" it becomes a
/// second later. Every formatter here re-checks the value *after* deciding its
/// precision and carries if it has to, which is why both `wattsNumber` and the
/// scaling loop below decide the precision twice rather than once.
enum ActivityFormat {

    /// What a number becomes when it is not a number. Sections whose data is
    /// missing are omitted rather than drawn, so this should only ever appear
    /// if a probe hands us a NaN.
    static let unknown = "n/a"

    static let byteUnits = ["B", "KB", "MB", "GB", "TB", "PB"]
    static let rateUnits = ["B/s", "kB/s", "MB/s", "GB/s", "TB/s", "PB/s"]

    static let spokenByteUnits = ["bytes", "kilobytes", "megabytes",
                                  "gigabytes", "terabytes", "petabytes"]
    static let spokenRateUnits = ["bytes per second", "kilobytes per second",
                                  "megabytes per second", "gigabytes per second",
                                  "terabytes per second", "petabytes per second"]

    // MARK: - the numbers

    /// A fraction in `0...1` as a whole percentage. Clamped, because a busy
    /// fraction of 1.02 is a rounding artefact and "102%" is a bug report.
    static func percent(_ fraction: Double, unit: String = "%") -> String {
        guard fraction.isFinite else { return unknown }
        let clamped = min(1, max(0, fraction))
        let whole = Int((clamped * 100).rounded())
        return unit == "%" ? "\(whole)%" : "\(whole) \(unit)"
    }

    /// Watts. Sub-watt values keep two decimals, because a Neural Engine at
    /// 0.07 W and one at 0.00 W are a meaningful difference and "0.1 W" hides
    /// it.
    static func watts(_ value: Double, unit: String = "W") -> String {
        guard let number = wattsNumber(value) else { return unknown }
        return "\(number) \(unit)"
    }

    /// A wattage that was printed on a label rather than measured: an
    /// adapter's rating. Whole watts, because that is what the rating is. A
    /// 30 W adapter shown as "30.0 W" reads as a measurement that happened to
    /// land on a round number, and invites the reader to watch a decimal place
    /// that will never move.
    static func wattsRating(_ value: Double, unit: String = "W") -> String {
        guard value.isFinite, value >= 0 else { return unknown }
        return "\(String(format: "%.0f", value)) \(unit)"
    }

    /// The digits of a wattage with no unit attached, or nil when the value is
    /// not a reading. The power headline draws the number and its unit in two
    /// different fonts, and asking for the number on its own is how it gets
    /// them without taking a formatted string apart again afterwards.
    ///
    /// The carry lives here. One decimal is right up to a hundred watts, but
    /// 99.95 printed with one decimal is "100.0", which is wider than both the
    /// "99.9" before it and the "100" after it: on a Mac hovering at a hundred
    /// watts the headline would jump two characters wider several times a
    /// minute. Deciding the precision a second time, from the value as it would
    /// print rather than as it was measured, is what stops that.
    ///
    /// The one-watt boundary deliberately does not carry. "1.00" is the same
    /// width as the "0.99" before it, so there is no jitter to prevent, and the
    /// two decimals are the whole reason sub-watt values are readable.
    static func wattsNumber(_ value: Double) -> String? {
        guard value.isFinite, value >= 0 else { return nil }
        var digits = value < 1 ? 2 : (value < 100 ? 1 : 0)
        let power = pow(10.0, Double(digits))
        if digits > 0, (value * power).rounded() / power >= 100 { digits = 0 }
        return String(format: "%.\(digits)f", value)
    }

    /// A span of time split into whole hours and whole minutes, or nil when
    /// there is no span to state.
    ///
    /// Seconds are deliberately dropped rather than rounded into the display.
    /// The only durations this panel shows are a battery gauge's estimate of
    /// when the cell fills or empties, and that estimate moves by minutes the
    /// moment anybody opens an application. A readout precise to the second
    /// would be making a claim about its own accuracy that the number behind it
    /// cannot support.
    static func hoursMinutes(_ seconds: TimeInterval) -> (hours: Int, minutes: Int)? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let total = Int((seconds / 60).rounded())
        guard total > 0 else { return nil }
        return (total / 60, total % 60)
    }

    /// A span of time, as "2 h 47 m" or "47 m".
    static func duration(_ seconds: TimeInterval) -> String {
        guard let split = hoursMinutes(seconds) else { return unknown }
        return split.hours > 0 ? "\(split.hours) h \(split.minutes) m" : "\(split.minutes) m"
    }

    /// A clock, given in megahertz, shown in whichever unit reads shorter.
    static func megahertz(_ value: Double,
                          units: (mhz: String, ghz: String) = ("MHz", "GHz")) -> String {
        guard value.isFinite, value >= 0 else { return unknown }
        if value.rounded() < 1000 {
            return "\(String(format: "%.0f", value)) \(units.mhz)"
        }
        return "\(String(format: "%.2f", value / 1000)) \(units.ghz)"
    }

    /// A quantity of memory, in 1024s.
    static func bytes(_ value: UInt64, units: [String] = byteUnits) -> String {
        scale(Double(value), base: 1024, units: units)
    }

    /// A rate of transfer, in 1000s.
    static func bytesPerSecond(_ value: Double, units: [String] = rateUnits) -> String {
        guard value.isFinite else { return unknown }
        return scale(max(0, value), base: 1000, units: units)
    }

    // MARK: - the scaling

    /// How many decimals a scaled value earns. The base unit never gets any:
    /// "1023.0 B" is noise, and a byte is already the smallest thing there is.
    private static func digits(for value: Double, unitIndex: Int) -> Int {
        guard unitIndex > 0 else { return 0 }
        return value < 100 ? 1 : 0
    }

    private static func scale(_ value: Double, base: Double, units: [String]) -> String {
        guard value.isFinite, !units.isEmpty else { return unknown }
        var v = max(0, value)
        var index = 0
        while v >= base && index < units.count - 1 {
            v /= base
            index += 1
        }

        // The carry. Decide the precision, then check whether printing at that
        // precision would round the value up into the unit above.
        var d = digits(for: v, unitIndex: index)
        let power = pow(10.0, Double(d))
        if (v * power).rounded() / power >= base, index < units.count - 1 {
            v /= base
            index += 1
            d = digits(for: v, unitIndex: index)
        }

        return "\(String(format: "%.\(d)f", v)) \(units[index])"
    }
}
