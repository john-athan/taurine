import Foundation

/// The shape of this particular chip. 🧬
///
/// Read once from `hw.perflevel*` and then never again: core counts do not
/// change while a process lives, and re-reading them every second would be
/// exactly the kind of idle cost this app exists to avoid.
///
/// Two facts about Apple Silicon are baked in here, both verified on the
/// machine rather than assumed:
///
///   • Efficiency cores own the low logical CPU numbers. Pinning three
///     background-QoS threads lights up `cpu0…cpu2` on an M4 Pro; six
///     user-interactive threads light up `cpu4…cpu13`. `hw.perflevel0` is the
///     *performance* level, so the sysctl order is the reverse of the CPU
///     numbering, and swapping the two is the easy mistake this comment exists
///     to prevent.
///
///   • A performance level is not always one cluster. An M4 Pro reports ten
///     performance cores with `cpusperl2 = 5`: two clusters of five, which is
///     also how IOReport names its channels (`PCPU0`, `PCPU1`). Splitting on
///     the L2 sharing group reproduces the hardware's own grouping.
///
/// An Intel Mac reports a single performance level and lands here as one
/// cluster, which is the honest answer for a chip with no efficiency cores.
struct CPUTopology {

    struct Cluster {
        /// Short, stable identity: `E`, `P` on a single-cluster chip, `P0` and
        /// `P1` where the level is split. Matches the IOReport channel naming.
        let id: String
        let kind: CoreKind
        /// Logical CPU numbers, in the order `host_processor_info` returns them.
        let coreIDs: [Int]
    }

    let clusters: [Cluster]

    var coreCount: Int { clusters.reduce(0) { $0 + $1.coreIDs.count } }

    /// The machine Taurine is running on. Computed on first use, then cached
    /// for the life of the process.
    static let current = CPUTopology.detect()

    // MARK: - detection

    /// One entry of `hw.perflevel<n>.*`, as read from sysctl.
    struct PerfLevel {
        let name: String
        let logicalCPUs: Int
        /// Cores sharing one L2, which is the cluster size. Zero when the
        /// sysctl is missing, meaning "do not split".
        let coresPerL2: Int

        var kind: CoreKind {
            name.lowercased().hasPrefix("e") ? .efficiency : .performance
        }
    }

    /// The pure half of detection: levels in sysctl order (fastest first) go
    /// in, clusters in logical CPU order come out. Kept separate from the
    /// sysctl reads so it can be tested against chips this Mac is not.
    static func compose(levels: [PerfLevel]) -> CPUTopology {
        // Efficiency cores hold the low CPU numbers, so walk the levels in the
        // reverse of the order sysctl lists them.
        var next = 0
        var clusters: [Cluster] = []

        for level in levels.reversed() where level.logicalCPUs > 0 {
            let size = (level.coresPerL2 > 0 && level.coresPerL2 <= level.logicalCPUs)
                ? level.coresPerL2 : level.logicalCPUs
            let groups = Int((Double(level.logicalCPUs) / Double(size)).rounded(.up))
            let prefix = level.kind == .efficiency ? "E" : "P"

            for group in 0..<groups {
                let start = next + group * size
                let end = min(start + size, next + level.logicalCPUs)
                guard start < end else { continue }
                clusters.append(Cluster(id: groups == 1 ? prefix : "\(prefix)\(group)",
                                        kind: level.kind,
                                        coreIDs: Array(start..<end)))
            }
            next += level.logicalCPUs
        }

        // A chip that answers nothing still gets a truthful shape: one cluster
        // holding every core the kernel admits to.
        if clusters.isEmpty {
            let n = max(1, Int(sysctlInt("hw.logicalcpu") ?? 1))
            clusters = [Cluster(id: "P", kind: .performance, coreIDs: Array(0..<n))]
        }
        return CPUTopology(clusters: clusters)
    }

    private static func detect() -> CPUTopology {
        let count = Int(sysctlInt("hw.nperflevels") ?? 1)
        let levels = (0..<max(count, 1)).compactMap { i -> PerfLevel? in
            guard let logical = sysctlInt("hw.perflevel\(i).logicalcpu") else { return nil }
            return PerfLevel(name: sysctlString("hw.perflevel\(i).name") ?? "Performance",
                             logicalCPUs: Int(logical),
                             coresPerL2: Int(sysctlInt("hw.perflevel\(i).cpusperl2") ?? 0))
        }
        return compose(levels: levels)
    }

    // MARK: - sysctl

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int64>.size {
            return value
        }
        // Some keys are 32 bit. Ask again rather than misread eight bytes.
        var small: Int32 = 0
        var smallSize = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &small, &smallSize, nil, 0) == 0 else { return nil }
        return Int64(small)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
