import Foundation

/// Numbers that have to stay the same width while they change.
///
/// The interesting cases are the boundaries: where a unit carries, where the
/// decimal disappears, and where rounding would otherwise invent a unit nobody
/// uses ("1000 kB/s").
func runActivityFormatTests() {

    Check.suite("format: percentages") {
        Check.equal(ActivityFormat.percent(0), "0%", "idle")
        Check.equal(ActivityFormat.percent(1), "100%", "saturated")
        Check.equal(ActivityFormat.percent(0.585), "59%", "rounds to whole percent")
        Check.equal(ActivityFormat.percent(0.004), "0%", "a whisker of load is still zero percent")
        Check.equal(ActivityFormat.percent(1.02), "100%", "clamped above")
        Check.equal(ActivityFormat.percent(-0.1), "0%", "clamped below")
        Check.equal(ActivityFormat.percent(.nan), ActivityFormat.unknown, "not a number")
        Check.equal(ActivityFormat.percent(0.31, unit: "percent"), "31 percent", "spoken form")
    }

    Check.suite("format: watts") {
        Check.equal(ActivityFormat.watts(0), "0.00 W", "a sleeping neural engine keeps its decimals")
        Check.equal(ActivityFormat.watts(0.07), "0.07 W", "sub-watt values keep two decimals")
        Check.equal(ActivityFormat.watts(0.998), "1.00 W", "just under a watt rounds up but keeps its shape")
        Check.equal(ActivityFormat.watts(8.14), "8.1 W", "one decimal below a hundred")
        Check.equal(ActivityFormat.watts(14.25), "14.2 W", "and above ten")
        Check.equal(ActivityFormat.watts(102.4), "102 W", "no decimals above a hundred")
        Check.equal(ActivityFormat.watts(-1), ActivityFormat.unknown, "negative power is not a reading")
        Check.equal(ActivityFormat.watts(.infinity), ActivityFormat.unknown, "infinite power is not a reading")
        Check.equal(ActivityFormat.watts(.nan), ActivityFormat.unknown, "and neither is a NaN")
        Check.equal(ActivityFormat.watts(8.14, unit: "watts"), "8.1 watts", "spoken form")
    }

    Check.suite("format: the hundred-watt band, where the precision changes") {
        // A Mac under sustained load sits right here, and the headline crosses
        // this boundary several times a minute. "100.0 W" is two characters
        // wider than the "100 W" it becomes a moment later, which is exactly
        // the jitter the precision rules exist to prevent.
        Check.equal(ActivityFormat.watts(99.9), "99.9 W", "below the boundary, one decimal")
        Check.equal(ActivityFormat.watts(99.94), "99.9 W", "and rounding down stays there")
        Check.equal(ActivityFormat.watts(99.95), "100 W",
                    "rounding up carries into the band above rather than printing 100.0 W")
        Check.equal(ActivityFormat.watts(99.99), "100 W", "as does anything else that rounds to a hundred")
        Check.equal(ActivityFormat.watts(100), "100 W", "and the boundary itself")
        Check.equal(ActivityFormat.watts(100.04), "100 W", "and just past it")

        let crossing = [99.95, 100.0, 100.4, 137.0].map { ActivityFormat.watts($0) }
        Check.that(Set(crossing.map(\.count)).count == 1,
                   "nothing in the hundreds is wider than anything else in the hundreds")

        Check.equal(ActivitySpeech.watts(99.95), "100 watts", "the spoken form carries too")

        // The other boundary deliberately does not carry: "1.00" is the same
        // width as the "0.99" before it, and the decimals are the whole reason
        // a Neural Engine at 0.07 W is legible.
        Check.equal(ActivityFormat.watts(0.996), "1.00 W", "one watt keeps its two decimals")
    }

    Check.suite("format: the headline asks for the digits without the unit") {
        Check.equal(ActivityFormat.wattsNumber(14.25), "14.2", "the number the hero font draws")
        Check.equal(ActivityFormat.wattsNumber(99.95), "100", "with the same carry")
        Check.isNil(ActivityFormat.wattsNumber(.nan), "a NaN has no digits to draw")
        Check.isNil(ActivityFormat.wattsNumber(-0.5), "and neither has a negative")
    }

    Check.suite("format: frequencies") {
        Check.equal(ActivityFormat.megahertz(0), "0 MHz", "a parked cluster")
        Check.equal(ActivityFormat.megahertz(890), "890 MHz", "below a gigahertz")
        Check.equal(ActivityFormat.megahertz(999.6), "1.00 GHz", "rounding up crosses the unit")
        Check.equal(ActivityFormat.megahertz(1052), "1.05 GHz", "two decimals keep the detail")
        Check.equal(ActivityFormat.megahertz(4512), "4.51 GHz", "a performance core at full tilt")
        Check.equal(ActivityFormat.megahertz(.nan), ActivityFormat.unknown, "not a number")
        Check.equal(ActivityFormat.megahertz(3840, units: ("megahertz", "gigahertz")),
                    "3.84 gigahertz", "spoken form")
    }

    Check.suite("format: memory counts in 1024s") {
        Check.equal(ActivityFormat.bytes(0), "0 B", "nothing")
        Check.equal(ActivityFormat.bytes(1023), "1023 B", "the base unit never takes a decimal")
        Check.equal(ActivityFormat.bytes(1024), "1.0 KB", "one kilobyte")
        Check.equal(ActivityFormat.bytes(536_870_912), "512 MB", "no decimal above a hundred")
        Check.equal(ActivityFormat.bytes(25_769_803_776), "24.0 GB", "the RAM on the box")
        Check.equal(ActivityFormat.bytes(19_756_294_144), "18.4 GB", "a plausible amount in use")
        Check.equal(ActivityFormat.bytes(1_099_511_627_776), "1.0 TB", "a big machine")
        Check.equal(ActivityFormat.bytes(1_073_741_823), "1.0 GB",
                    "a byte under a gigabyte carries rather than printing 1024.0 MB")
        Check.equal(ActivityFormat.bytes(12_988_952_576, units: ActivityFormat.spokenByteUnits),
                    "12.1 gigabytes", "spoken form")
    }

    Check.suite("format: rates count in 1000s, across six orders of magnitude") {
        Check.equal(ActivityFormat.bytesPerSecond(0), "0 B/s", "an idle interface")
        Check.equal(ActivityFormat.bytesPerSecond(1), "1 B/s", "one byte")
        Check.equal(ActivityFormat.bytesPerSecond(812), "812 B/s", "hundreds")
        Check.equal(ActivityFormat.bytesPerSecond(1_500), "1.5 kB/s", "thousands")
        Check.equal(ActivityFormat.bytesPerSecond(118_000), "118 kB/s", "hundreds of thousands")
        Check.equal(ActivityFormat.bytesPerSecond(4_200_000), "4.2 MB/s", "millions")
        Check.equal(ActivityFormat.bytesPerSecond(1_250_000_000), "1.2 GB/s", "billions")
        Check.equal(ActivityFormat.bytesPerSecond(3_400_000_000_000), "3.4 TB/s", "trillions")
    }

    Check.suite("format: the carry that would invent a unit nobody uses") {
        Check.equal(ActivityFormat.bytesPerSecond(999_999), "1.0 MB/s",
                    "999.999 kB/s prints as a megabyte, not as 1000 kB/s")
        Check.equal(ActivityFormat.bytesPerSecond(999_999_999), "1.0 GB/s", "and again a unit up")
        Check.equal(ActivityFormat.bytesPerSecond(999.6), "1.0 kB/s",
                    "the carry out of the base unit works too")
    }

    Check.suite("format: rates are never negative and never infinite") {
        Check.equal(ActivityFormat.bytesPerSecond(-5), "0 B/s", "a counter that went backwards reads zero")
        Check.equal(ActivityFormat.bytesPerSecond(.nan), ActivityFormat.unknown, "not a number")
        Check.equal(ActivityFormat.bytesPerSecond(.infinity), ActivityFormat.unknown,
                    "a rate divided by a zero interval is not a reading")
    }

    Check.suite("format: widths hold still while values change") {
        // The reason for the precision rules: a readout whose digits move
        // sideways every second cannot be read at a glance.
        let climbing = [10.0, 11.4, 25.9, 99.9].map { ActivityFormat.watts($0) }
        Check.that(Set(climbing.map(\.count)).count == 1,
                   "every two-digit wattage prints the same number of characters")
        let rates = [1_100_000.0, 4_200_000, 9_900_000].map { ActivityFormat.bytesPerSecond($0) }
        Check.that(Set(rates.map(\.count)).count == 1,
                   "every single-digit megabyte rate prints the same number of characters")
    }
}
