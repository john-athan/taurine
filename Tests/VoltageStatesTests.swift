import Foundation

/// Undocumented registry blobs, read against bytes captured from real hardware.
///
/// Everything here is a parser over a byte layout Apple never wrote down, which
/// makes it the most likely thing in the power tile to quietly start lying. The
/// fixtures are the actual values this M4 Pro publishes, so a macOS that
/// reshuffles them shows up as a red test rather than as a chip that appears to
/// slow down under load.
func runVoltageStatesTests() {

    /// Pairs of little-endian UInt32, frequency then operating voltage, which
    /// is the layout every `voltage-states` property uses.
    func table(_ pairs: [(UInt32, UInt32)]) -> Data {
        var data = Data()
        for (frequency, voltage) in pairs {
            withUnsafeBytes(of: frequency.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: voltage.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// One 28-byte `perf-domains` record: index in byte zero, NUL-padded name
    /// from byte twelve.
    func domain(_ index: UInt8, _ name: String) -> Data {
        var record = Data(repeating: 0, count: 28)
        record[0] = index
        for (offset, byte) in name.utf8.enumerated() { record[12 + offset] = byte }
        return record
    }

    Check.suite("voltage-states: the M4 Pro's own tables") {
        // voltage-states1-sram, the efficiency cluster, in kilohertz.
        let efficiency = Check.unwrap(VoltageStates.frequenciesMHz(in: table([
            (1_020_000, 790), (1_404_000, 800), (1_788_000, 830), (2_112_000, 860),
            (2_352_000, 900), (2_532_000, 940), (2_592_000, 940),
        ])), "the efficiency table parses")
        Check.equal(efficiency?.count, 7, "seven operating points, one per active state")
        Check.equal(efficiency?.first, 1020, "bottom of the E cluster")
        Check.equal(efficiency?.last, 2592, "top of the E cluster")

        // voltage-states9, the GPU, in hertz and with a dead first row.
        let graphics = Check.unwrap(VoltageStates.frequenciesMHz(in: table([
            (0, 125), (338_000_000, 590), (618_000_000, 640), (796_000_000, 690),
        ])), "the GPU table parses")
        Check.equal(graphics?.count, 3, "the zero-hertz row pairs with the OFF state and is dropped")
        Check.equal(graphics?.first, 338, "so the first entry is the lowest real clock")
    }

    Check.suite("voltage-states: a frequency table is never sorted") {
        // Genuinely not monotonic on this Mac: the states are ordered by
        // voltage, and 1312 MHz sits at a lower voltage than 1242 MHz.
        let graphics = VoltageStates.frequenciesMHz(in: table([
            (1_182_000_000, 855), (1_312_000_000, 855), (1_242_000_000, 900), (1_380_000_000, 900),
        ]))
        Check.equal(graphics ?? [], [1182, 1312, 1242, 1380], "the order the hardware gave is the order kept")
    }

    Check.suite("voltage-states: what is not a frequency table") {
        // voltage-states1 on this Mac, whole: 65536 divided by the gigahertz in
        // voltage-states1-sram, rounded down, so 65536/1.020 opens it at 64250
        // and 65536/2.592 closes it at 25283. Reading it as megahertz makes a
        // loaded machine look idle.
        Check.isNil(VoltageStates.frequenciesMHz(in: table([
            (64250, 590), (46678, 640), (36653, 710), (31030, 770),
            (27863, 825), (25883, 880), (25283, 880),
        ])), "the reciprocal twin of the efficiency table is rejected")

        // The same encoding for a cluster whose ladder starts at 600 MHz rather
        // than this one's 1020: 65536/0.6 rounds down to 109226, and the size
        // test alone reads that as a plausible 109 MHz table in kilohertz. Only
        // the descent gives it away.
        Check.isNil(VoltageStates.frequenciesMHz(in: table([
            (109226, 600), (67423, 650), (49201, 720), (38460, 790), (31751, 860),
        ])), "a reciprocal table small enough to pass for kilohertz is rejected on its descent")

        // Two entries are enough to fall, and one is never enough.
        Check.isNil(VoltageStates.frequenciesMHz(in: table([(2000, 800), (1000, 700)])),
                    "a two-entry table that descends is a reciprocal too")
        Check.equal(VoltageStates.frequenciesMHz(in: table([(3200, 1)])) ?? [], [3200],
                    "a single operating point has no direction to fall in")

        // voltage-states0 and friends: a voltage list with no frequency at all.
        Check.isNil(VoltageStates.frequenciesMHz(in: table([(1, 665), (1, 720), (1, 800)])),
                    "a table whose frequency column is all ones is rejected")
        Check.isNil(VoltageStates.frequenciesMHz(in: table([(0, 125), (0, 125)])),
                    "and so is one that is all zeros")
        Check.isNil(VoltageStates.frequenciesMHz(in: Data([1, 2, 3, 4, 5])),
                    "a length that is not a whole number of pairs is rejected")
        Check.isNil(VoltageStates.frequenciesMHz(in: Data()), "as is an empty property")
    }

    Check.suite("voltage-states: scale is measured, not looked up by chip name") {
        // This Mac publishes its GPU table in hertz and its CPU tables in
        // kilohertz, side by side. Both have to land in the same place.
        Check.equal(VoltageStates.frequenciesMHz(in: table([(3_200_000_000, 1)])) ?? [], [3200], "hertz")
        Check.equal(VoltageStates.frequenciesMHz(in: table([(3_200_000, 1)])) ?? [], [3200], "kilohertz")
        Check.equal(VoltageStates.frequenciesMHz(in: table([(3200, 1)])) ?? [], [3200], "megahertz")
    }

    Check.suite("perf-domains: the mapping this M4 Pro publishes") {
        var data = Data()
        for (index, name) in [(UInt8(0), "SOC"), (1, "ECPU"), (2, "DCS"), (5, "PCPU"),
                              (8, "ANE"), (11, "DISP"), (13, "PCPU1")] {
            data.append(domain(index, name))
        }
        let domains = VoltageStates.parseDomains(data)
        Check.equal(domains["ECPU"], 1, "the efficiency cluster reads voltage-states1")
        Check.equal(domains["PCPU"], 5, "the first performance cluster reads voltage-states5")
        Check.equal(domains["PCPU1"], 13, "and the second reads voltage-states13")
        Check.equal(domains.count, 7, "every record is accounted for")
        Check.isNil(domains["GFX"], "this chip names no graphics domain, which is why the GPU goes by shape")
    }

    Check.suite("perf-domains: a layout we do not recognise is dropped whole") {
        // A wrong stride makes every index wrong, so a partial read is worse
        // than no read.
        Check.equal(VoltageStates.parseDomains(Data(repeating: 0x41, count: 30)).count, 0,
                    "a length that is not a whole number of records")
        Check.equal(VoltageStates.parseDomains(Data(repeating: 0xFF, count: 28)).count, 0,
                    "a name field that is not printable ASCII")
        Check.equal(VoltageStates.parseDomains(nil).count, 0, "an absent property")
        Check.equal(VoltageStates.parseDomains(Data(repeating: 0, count: 28)).count, 0,
                    "an empty name field")

        // Trailing rubbish after the name means the stride is not 28 here.
        var wrongStride = domain(1, "ECPU")
        wrongStride[27] = 0x7A
        Check.equal(VoltageStates.parseDomains(wrongStride).count, 0, "a record that does not end in padding")
    }

    Check.suite("voltage-states: looking a cluster's table up by name") {
        let states = VoltageStates(
            domains: ["ECPU": 1, "PCPU": 5, "PCPU1": 13],
            tables: [
                .init(index: 1, isSRAM: false, frequenciesMHz: [600, 700, 800, 900, 1000, 1100, 1200]),
                .init(index: 1, isSRAM: true, frequenciesMHz: [1020, 1404, 1788, 2112, 2352, 2532, 2592]),
                .init(index: 5, isSRAM: true, frequenciesMHz: [1260, 4512]),
                .init(index: 13, isSRAM: true, frequenciesMHz: [1260, 4512]),
            ])

        Check.equal(states.frequenciesMHz(domain: ["ECPU"], operatingStates: 7)?.last, 2592,
                    "the sram spelling wins, because it is the one with real frequencies on it")
        Check.equal(states.frequenciesMHz(domain: ["DIE_0_PCPU1", "PCPU1"], operatingStates: 2)?.last, 4512,
                    "a die-qualified name falls back to the plain one")
        Check.isNil(states.frequenciesMHz(domain: ["ECPU"], operatingStates: 6),
                    "a table with the wrong number of entries is refused, not trimmed")
        Check.isNil(states.frequenciesMHz(domain: ["GFX"], operatingStates: 7),
                    "a domain nobody named has no table")
    }

    Check.suite("voltage-states: looking a table up by shape alone") {
        // The five shapes this M4 Pro's pmgr node publishes that survive
        // parsing, with the GPU's sixteen-row tables trimmed to the fifteen
        // operating points its GPUPH channel counts. Four of them carry that
        // shape, byte for byte: voltage-states9 and 14 and both of their sram
        // twins. voltage-states28 and 29 are the two fabric clocks, the same
        // length as each other and nothing alike.
        let graphics: [Double] = [338, 618, 796, 924, 952, 1056, 1062, 1182,
                                  1182, 1312, 1242, 1380, 1326, 1470, 1578]
        let states = VoltageStates(
            domains: [:],
            tables: [
                .init(index: 9, isSRAM: false, frequenciesMHz: graphics),
                .init(index: 9, isSRAM: true, frequenciesMHz: graphics),
                .init(index: 14, isSRAM: false, frequenciesMHz: graphics),
                .init(index: 14, isSRAM: true, frequenciesMHz: graphics),
                .init(index: 31, isSRAM: false, frequenciesMHz: [338, 618, 796, 992, 1188, 1380, 1470]),
                .init(index: 28, isSRAM: false, frequenciesMHz: [801, 1602, 2004, 2004]),
                .init(index: 29, isSRAM: false, frequenciesMHz: [534, 801, 1068, 1068]),
            ])

        // Four candidates that agree are not an ambiguity.
        Check.equal(states.frequenciesMHz(operatingStates: 15)?.last, 1578,
                    "candidates that agree give an answer")
        Check.equal(states.frequenciesMHz(operatingStates: 15)?.count, 15, "the whole table, in DVFS order")
        // Two tables of the same size that disagree, and neither is sram.
        Check.isNil(states.frequenciesMHz(operatingStates: 4),
                    "candidates that disagree give silence")
        Check.equal(states.frequenciesMHz(operatingStates: 7)?.last, 1470,
                    "a shape only one table has needs no agreement")
        Check.isNil(states.frequenciesMHz(operatingStates: 19), "and no candidate at all gives silence too")
    }

    Check.hardwareSuite("voltage-states: the rule against every property this Mac publishes") {
        // The fixtures above are bytes; this is the live registry. Whatever the
        // pmgr node holds on the Mac running the tests, every table that
        // survives has to be a table a clock could be described by, and none of
        // them may be one of the reciprocals. An Intel Mac has no such node,
        // and nothing to say here.
        guard (CPUTopology.sysctlInt("hw.optional.arm64") ?? 0) == 1 else { return }
        let live = VoltageStates.read()
        Check.that(!live.isEmpty, "an Apple Silicon Mac publishes at least one usable voltage-states table")
        let descending = live.tables.filter {
            $0.frequenciesMHz.count > 1 && zip($0.frequenciesMHz, $0.frequenciesMHz.dropFirst()).allSatisfy { $0 > $1 }
        }
        Check.equal(descending.count, 0,
                    "no surviving table falls at every step (\(descending.map(\.index)) do)")
        let implausible = live.tables.filter {
            ($0.frequenciesMHz.min() ?? 0) <= 0 || ($0.frequenciesMHz.max() ?? 0) > 20_000
        }
        Check.equal(implausible.count, 0,
                    "and every entry of every survivor is a clock speed (\(implausible.map(\.index)) are not)")
    }
}
