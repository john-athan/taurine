import Foundation
import IOKit

/// The frequency table. 🎚️
///
/// IOReport says how many ticks a core spent in state five. It does not say
/// what state five runs at. That number lives somewhere else entirely: in the
/// IO registry, on the `pmgr` node of `AppleARMIODevice`, in a pile of
/// undocumented properties called `voltage-states<n>`. Each is an array of
/// eight-byte records, frequency first and the operating voltage second, and
/// the frequency column in DVFS order is exactly the table the residency
/// counters are indexed by.
///
/// The hard part is not parsing them, it is knowing *which* table belongs to
/// which cluster. This Mac publishes eighteen of them. `macmon` answers by
/// hard-coding `voltage-states1-sram` for the efficiency cores and
/// `voltage-states5-sram` for the performance cores, which is correct on an M4
/// Pro and says nothing about its second performance cluster.
///
/// There is a better answer sitting on the same node. `perf-domains` is a table
/// of twenty-eight byte records: the first byte is a `voltage-states` index and
/// the last sixteen are a NUL-padded name. Read on this M4 Pro it says, in so
/// many words:
///
///     SOC → 0    ECPU → 1    DCS → 2     PCPU → 5
///     ANE → 8    DISP → 11   PCPU1 → 13  SOC_AFC → 28   SOC_AFI → 29
///
/// and `ECPU`, `PCPU` and `PCPU1` are, character for character, the names
/// IOReport uses for the same three clusters. So the binding is published by
/// the machine rather than guessed by us, and it extends to chips with more
/// clusters than this one has for free.
///
/// Two traps for the next reader:
///
///   • The plain `voltage-states1` and `voltage-states5` do **not** hold
///     frequencies on this chip. They hold the reciprocal, 65536 divided by the
///     frequency in gigahertz and rounded down: `voltage-states1` descends from
///     64250 to 25283 alongside `voltage-states1-sram`'s 1020000 to 2592000
///     kilohertz, and 65536/1.020 is 64250 while 65536/2.592 is 25283. Reading
///     one as megahertz gives a machine that appears to slow down under load.
///     Neither the suffix nor the size of the numbers is trusted: a table that
///     falls at every step is a reciprocal whatever scale it is read at, and
///     that is what disqualifies it.
///
///   • Do not "fix" a frequency table by sorting it. The GPU's table on this
///     Mac genuinely is not monotonic (…1182, 1182, 1312, 1242, 1380…), because
///     the DVFS states are voltage-ordered rather than frequency-ordered. A
///     sort would silently misalign every state above the eighth.
///
/// The GPU is the one thing `perf-domains` here does not name, so its table is
/// found by shape: the only candidates with as many usable entries as the GPU
/// channel has operating states, and they have to agree with each other before
/// any of them is believed.
struct VoltageStates {

    /// One `voltage-states<index>` property, already scaled and trimmed.
    struct Table {
        let index: Int
        /// True for the `-sram` spelling, which is the one that holds real
        /// frequencies on Apple Silicon and therefore wins every tie.
        let isSRAM: Bool
        /// Operating points in MHz, in DVFS order, with the dead leading
        /// entries (the zero-hertz row that pairs with a channel's `OFF`
        /// state) already removed.
        let frequenciesMHz: [Double]
    }

    /// Domain name to `voltage-states` index, from `perf-domains`.
    let domains: [String: Int]
    let tables: [Table]

    var isEmpty: Bool { tables.isEmpty }

    // MARK: - lookup

    /// The table for a named power domain, checked against the number of
    /// operating states the channel actually has.
    ///
    /// A count mismatch returns nil rather than a truncated table: if the two
    /// disagree, one of them is describing different hardware than the other,
    /// and lining them up anyway is how a Mac ends up reporting 4.5 GHz on its
    /// efficiency cores.
    func frequenciesMHz(domain names: [String], operatingStates: Int) -> [Double]? {
        for name in names {
            guard let index = domains[name] else { continue }
            let candidates = tables.filter { $0.index == index && $0.frequenciesMHz.count == operatingStates }
            if let best = candidates.first(where: \.isSRAM) ?? candidates.first {
                return best.frequenciesMHz
            }
        }
        return nil
    }

    /// The table for a domain nobody named, found by how many operating points
    /// it has. Only answers when every candidate of that shape agrees, so an
    /// ambiguity is a silence rather than a coin toss.
    func frequenciesMHz(operatingStates: Int) -> [Double]? {
        let sized = tables.filter { $0.frequenciesMHz.count == operatingStates }
        let candidates = sized.contains(where: \.isSRAM) ? sized.filter(\.isSRAM) : sized
        guard let first = candidates.first else { return nil }
        guard candidates.allSatisfy({ $0.frequenciesMHz == first.frequenciesMHz }) else { return nil }
        return first.frequenciesMHz
    }

    // MARK: - reading the registry

    /// Read `pmgr`. Returns an empty set of tables rather than throwing: a Mac
    /// without these properties still gets residency, it just does not get a
    /// frequency, and that is a degraded panel rather than a broken one.
    ///
    /// Deliberately not cached across the life of the process. The panel's
    /// promise is that closing it gives everything back (ADR 0002), and one
    /// registry walk on open is cheap enough that a permanent copy is not worth
    /// arguing about.
    static func read() -> VoltageStates {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleARMIODevice"),
                                           &iterator) == KERN_SUCCESS else {
            return VoltageStates(domains: [:], tables: [])
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard name(of: entry) == "pmgr" else { continue }

            var raw: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = raw?.takeRetainedValue() as? [String: Any] else { continue }

            return VoltageStates(domains: parseDomains(properties["perf-domains"] as? Data),
                                 tables: parseTables(properties))
        }
        return VoltageStates(domains: [:], tables: [])
    }

    private static func name(of entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return "" }
        return String(cString: buffer)
    }

    // MARK: - parsing

    /// `perf-domains`: 28 bytes per record, `voltage-states` index in byte 0,
    /// NUL-padded name in bytes 12 through 27.
    ///
    /// The layout is undocumented, so it is checked rather than trusted: a
    /// record whose name is not a plain ASCII identifier means the stride is
    /// wrong, and a wrong stride means every index is wrong, so the whole table
    /// is thrown away and the caller falls back to matching by shape.
    static func parseDomains(_ data: Data?) -> [String: Int] {
        let stride = 28, nameOffset = 12
        guard let data, data.count >= stride, data.count % stride == 0 else { return [:] }

        var domains: [String: Int] = [:]
        for start in Swift.stride(from: 0, to: data.count, by: stride) {
            let record = Array(data[data.startIndex + start ..< data.startIndex + start + stride])
            let field = record[nameOffset...].prefix { $0 != 0 }
            guard !field.isEmpty,
                  field.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
                  record[(nameOffset + field.count)...].allSatisfy({ $0 == 0 }),
                  let name = String(bytes: field, encoding: .ascii) else {
                return [:]
            }
            domains[name] = Int(record[0])
        }
        return domains
    }

    /// Every `voltage-states<n>` and `voltage-states<n>-sram` property, parsed,
    /// scaled and trimmed. Properties that do not survive the plausibility
    /// check are dropped, which is what keeps the reciprocal tables out.
    private static func parseTables(_ properties: [String: Any]) -> [Table] {
        var tables: [Table] = []
        for (key, value) in properties {
            guard key.hasPrefix("voltage-states"), let data = value as? Data else { continue }
            var suffix = Substring(key.dropFirst("voltage-states".count))
            let isSRAM = suffix.hasSuffix("-sram")
            if isSRAM { suffix = suffix.dropLast("-sram".count) }
            guard let index = Int(suffix), let frequencies = frequenciesMHz(in: data) else { continue }
            tables.append(Table(index: index, isSRAM: isSRAM, frequenciesMHz: frequencies))
        }
        return tables
    }

    /// Pairs of little-endian `UInt32`, frequency then voltage. Nil when the
    /// frequency column is not a set of clock speeds: because it descends, or
    /// because no scale puts it anywhere a clock could be.
    static func frequenciesMHz(in data: Data) -> [Double]? {
        guard data.count >= 8, data.count % 8 == 0 else { return nil }

        var raw: [UInt32] = []
        raw.reserveCapacity(data.count / 8)
        data.withUnsafeBytes { bytes in
            for offset in Swift.stride(from: 0, to: bytes.count, by: 8) {
                raw.append(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
        }

        // The zero-hertz rows at the head pair up with a channel's OFF state,
        // which the residency fold has already set aside. Trailing duplicates
        // are left alone: they are real states the hardware can sit in.
        let operating = Array(raw.drop(while: { $0 == 0 }))
        guard let peak = operating.max(), peak > 0 else { return nil }

        // A DVFS table climbs. Not monotonically, as the GPU's proves, but no
        // operating-point table on this Mac falls at every single step, and the
        // reciprocal twins all do, because dividing 65536 by a rising frequency
        // can only fall. That test is scale-free, which the size test below is
        // not: the size test accepts a peak between 1e5 and 2e7 read as
        // kilohertz, and a reciprocal peak reaches 1e5 the moment a cluster's
        // lowest operating point drops to 655 MHz (65536/0.65536 = 100000).
        // For a cluster starting at 600 MHz the reciprocal peak is 109226,
        // which reads as a perfectly plausible 109 MHz and is nothing of the
        // sort.
        if operating.count > 1, zip(operating, operating.dropFirst()).allSatisfy({ $0 > $1 }) {
            return nil
        }

        // The scale is not fixed even within one chip: this Mac gives the GPU's
        // table in hertz (338000000) and the efficiency cluster's in kilohertz
        // (1020000), in the same property family, with nothing to tell them
        // apart but the size of the numbers. So take whichever reading puts the
        // top of the table somewhere a clock could actually be.
        for divisor in [1e6, 1e3, 1.0] {
            let top = Double(peak) / divisor
            guard (100.0...20_000.0).contains(top) else { continue }
            return operating.map { Double($0) / divisor }
        }
        return nil
    }
}
