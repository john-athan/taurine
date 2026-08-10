import Foundation

/// The arithmetic. 🧮
///
/// Everything in this file is a pure function over numbers and strings that
/// IOReport handed us, which is deliberate: the parts of a power reading that
/// can be *wrong* rather than merely absent are all here, and they are all
/// testable without a Mac in the loop. `EnergyProbe` does the talking; this
/// does the thinking.
///
/// Three conversions, and each one has a trap.
///
///   • **Energy to watts.** The counters are cumulative joules in a unit the
///     channel names itself. This Mac reports `mJ` for most domains and `nJ`
///     for the GPU, and it reports `uJ` for the PCIe ports, all in the same
///     group. Hard-coding any one of those would be wrong by a factor of a
///     million somewhere. An unrecognised label yields nil, never a number: a
///     missing power tile is a nuisance, a power tile reading 70 million watts
///     is a bug report.
///
///   • **Residency to megahertz.** A state channel reports how many ticks the
///     core spent in each DVFS state. The inactive states come first and are
///     named (`DOWN`, `IDLE` on the CPU, `OFF` on the GPU); everything after
///     them is an operating point, in the same order as the frequency table
///     from `voltage-states`. The average is weighted by residency over the
///     *active* ticks only, so the answer is "how fast it ran while it ran",
///     not "how fast it ran counting the time it was asleep as zero". If the
///     count of active states and the length of the frequency table disagree,
///     the alignment is a guess, so no frequency comes out at all.
///
///   • **Channel name to cluster.** IOReport names CPU core channels three
///     different ways depending on the chip: `ECPU000` on an M4 Pro,
///     `DIE_1_PCPU1_CPU0` on an Ultra, and a bare `PCPU7` on some others. The
///     easy mistake is reading the leading digits of `DIE_1_…` as a core
///     number. The die prefix comes off first, always.
enum EnergyArithmetic {

    // MARK: - energy

    /// Joules per count for an IOReport energy unit label. Nil means "this
    /// label is not one we can honestly scale", which is the whole point.
    ///
    /// `µJ` with the real micro sign is accepted alongside the ASCII `uJ`
    /// because both spellings appear in Apple's tooling and neither costs
    /// anything to allow.
    static func joulesPerCount(_ unit: String) -> Double? {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "nJ": return 1e-9
        case "uJ", "µJ": return 1e-6
        case "mJ": return 1e-3
        case "J":  return 1
        case "kJ": return 1e3
        default:   return nil
        }
    }

    /// Watts from an energy delta, its unit label, and the interval it covers.
    ///
    /// Nil for an unknown unit or a non-positive interval. Negative deltas are
    /// let through rather than clamped: a counter that went backwards is a fact
    /// about the machine, and the caller decides what to do about it.
    static func watts(energy: Int64, unit: String, over seconds: TimeInterval) -> Double? {
        guard seconds > 0, let scale = joulesPerCount(unit) else { return nil }
        return Double(energy) * scale / seconds
    }

    /// `DIE_1_CPU Energy` becomes `CPU Energy`.
    ///
    /// Ultra chips are two dies in one package and prefix every channel with
    /// which die it came from. Both dies' watts belong in the same total, so
    /// the prefix comes off before the name is matched. A name that merely
    /// starts with the letters `DIE_` and no number is left alone.
    static func withoutDiePrefix(_ channel: String) -> String {
        guard channel.hasPrefix("DIE_") else { return channel }
        let afterDie = channel.dropFirst(4)
        let digits = afterDie.prefix(while: \.isNumber)
        guard !digits.isEmpty, afterDie.dropFirst(digits.count).hasPrefix("_") else { return channel }
        return String(afterDie.dropFirst(digits.count + 1))
    }

    // MARK: - residency

    /// The states a residency channel spends *not* running. They always come
    /// first in the state list, so a name test is only needed to find where the
    /// operating points begin.
    private static let idleStateNames: Set<String> = ["DOWN", "IDLE", "OFF"]

    /// What one residency channel did over the interval, before any division.
    ///
    /// Kept as sums rather than ratios so a cluster's cores can be added up and
    /// divided once, which weights each core by how long it was actually
    /// counting instead of averaging four percentages of four different
    /// denominators.
    struct Fold {
        /// Ticks in an operating state.
        var activeTicks: Double = 0
        /// Every tick the channel accounted for, running or not.
        var totalTicks: Double = 0
        /// Σ (ticks in state × that state's MHz). Nil when no frequency table
        /// could be lined up against the states.
        var frequencyWeightedTicks: Double?

        /// Fraction of the interval spent in an operating state, in `0...1`.
        var activeResidency: Double? {
            totalTicks > 0 ? min(1, max(0, activeTicks / totalTicks)) : nil
        }

        /// Residency-weighted mean operating frequency, in MHz. Nil when the
        /// channel never left idle: there is no average of no samples, and a
        /// floor pulled from the bottom of the frequency table would be a
        /// number nobody measured.
        var frequencyMHz: Double? {
            guard let weighted = frequencyWeightedTicks, activeTicks > 0 else { return nil }
            return weighted / activeTicks
        }

        /// Add another core's interval to this one.
        static func + (lhs: Fold, rhs: Fold) -> Fold {
            var sum = Fold()
            sum.activeTicks = lhs.activeTicks + rhs.activeTicks
            sum.totalTicks = lhs.totalTicks + rhs.totalTicks
            switch (lhs.frequencyWeightedTicks, rhs.frequencyWeightedTicks) {
            case let (l?, r?): sum.frequencyWeightedTicks = l + r
            case let (l?, nil): sum.frequencyWeightedTicks = l
            case let (nil, r?): sum.frequencyWeightedTicks = r
            case (nil, nil): sum.frequencyWeightedTicks = nil
            }
            return sum
        }
    }

    /// How many of a channel's states are operating points rather than rest.
    ///
    /// This is the number a frequency table has to match, so it is worked out
    /// from the state names the hardware declares rather than from a count the
    /// caller guessed.
    static func operatingStateCount(_ states: [IOReportBridge.Residency]) -> Int {
        states.filter { !idleStateNames.contains($0.name) }.count
    }

    /// Fold one channel's states against a frequency table.
    ///
    /// `frequenciesMHz` must already have had its dead leading entries dropped,
    /// so that its first element is the frequency of the first state that is
    /// not `DOWN`, `IDLE` or `OFF`. `VoltageStates` does that trimming, because
    /// that is where the zero-hertz `OFF` row of the GPU table lives.
    ///
    /// Pass an empty table to get residency without a frequency, which is the
    /// honest answer on a machine whose `voltage-states` we could not read.
    static func fold(states: [IOReportBridge.Residency], frequenciesMHz: [Double]) -> Fold {
        var fold = Fold()
        var operatingPoints: [Double] = []

        for state in states {
            let ticks = Double(max(0, state.ticks))
            fold.totalTicks += ticks
            guard !idleStateNames.contains(state.name) else { continue }
            fold.activeTicks += ticks
            operatingPoints.append(ticks)
        }

        // Alignment is the only thing that can silently produce a wrong number,
        // so it has to be exact or nothing.
        guard !frequenciesMHz.isEmpty, operatingPoints.count == frequenciesMHz.count else {
            return fold
        }
        fold.frequencyWeightedTicks = zip(operatingPoints, frequenciesMHz).reduce(0) { $0 + $1.0 * $1.1 }
        return fold
    }

    // MARK: - cluster identity

    /// Which rung of the chip a cluster sits on. The order of the cases is the
    /// order the kernel numbers their cores in, lowest logical CPU first, which
    /// is what makes sorting by it line the clusters up with `CPUTopology`.
    enum Tier: Int, Comparable {
        case efficiency = 0
        case middle = 1
        case performance = 2

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The channel-name prefix Apple uses for this rung. `MCPU` appeared on
        /// the M5 Pro and Max, where it is a genuine middle tier rather than a
        /// renamed efficiency cluster.
        var prefix: String {
            switch self {
            case .efficiency: return "ECPU"
            case .middle: return "MCPU"
            case .performance: return "PCPU"
            }
        }
    }

    /// One cluster, as IOReport names it.
    ///
    /// The sort is tier first and die second, which looks backwards until you
    /// count cores on an Ultra. That chip is two dies, each with an efficiency
    /// cluster and two performance clusters, and the kernel still numbers
    /// *every* efficiency core before *any* performance core: `cpu0…cpu3` are
    /// both dies' efficiency cores. Sorting by die first would produce
    /// E, P, P, E, P, P and hang die one's efficiency frequency on a
    /// performance cluster.
    struct ClusterChannel: Hashable, Comparable {
        let die: Int
        let tier: Tier
        let index: Int

        static func < (lhs: ClusterChannel, rhs: ClusterChannel) -> Bool {
            (lhs.tier.rawValue, lhs.die, lhs.index) < (rhs.tier.rawValue, rhs.die, rhs.index)
        }

        /// The name this cluster goes by in the `pmgr` node's `perf-domains`
        /// table, which is where its frequency table is found. Verified on an
        /// M4 Pro: the two performance clusters are `PCPU` and `PCPU1`, so the
        /// first cluster of a tier carries no index at all.
        var domainName: String {
            index == 0 ? tier.prefix : "\(tier.prefix)\(index)"
        }

        /// Same name with the die prefix back on, for chips that publish their
        /// domains per die. Tried first, falls back to `domainName`.
        var dieQualifiedDomainName: String {
            "DIE_\(die)_\(domainName)"
        }
    }

    /// Read a `CPU Core Performance States` channel name as a cluster identity.
    ///
    /// Handles all three shapes this API is known to produce:
    ///
    ///     ECPU000            M4 Pro:  tier E, cluster 0, core 0
    ///     PCPU140            M4 Pro:  tier P, cluster 1, core 4
    ///     PCPU7              some chips: tier P, cluster 0, core 7
    ///     DIE_1_PCPU1_CPU0   Ultra:   die 1, tier P, cluster 1, core 0
    ///
    /// The `_CPU` separator, where present, says exactly where the cluster
    /// number ends. Where it is absent the digits are single: the first is the
    /// cluster, the rest belong to the core, and a lone digit is a core in
    /// cluster zero. Returns nil for anything that is not a CPU core channel,
    /// which is how `GPUPH` and friends fall through.
    static func clusterChannel(forCoreChannel name: String) -> ClusterChannel? {
        var rest = Substring(name)
        var die = 0

        // "DIE_1_..." first, so its digits never get read as a core number.
        if rest.hasPrefix("DIE_") {
            let afterDie = rest.dropFirst(4)
            let digits = afterDie.prefix(while: \.isNumber)
            guard !digits.isEmpty, afterDie.dropFirst(digits.count).hasPrefix("_") else { return nil }
            die = Int(digits) ?? 0
            rest = afterDie.dropFirst(digits.count + 1)
        }

        guard let tier = [Tier.efficiency, .middle, .performance].first(where: { rest.hasPrefix($0.prefix) }) else {
            return nil
        }
        rest = rest.dropFirst(tier.prefix.count)

        if let separator = rest.range(of: "_CPU") {
            let clusterDigits = rest[rest.startIndex..<separator.lowerBound]
            guard clusterDigits.allSatisfy(\.isNumber) else { return nil }
            return ClusterChannel(die: die, tier: tier, index: clusterDigits.isEmpty ? 0 : Int(clusterDigits) ?? 0)
        }

        guard !rest.isEmpty, rest.allSatisfy(\.isNumber) else { return nil }
        // A single digit is a core number on a single-cluster tier; two or more
        // put the cluster first.
        let index = rest.count >= 2 ? Int(String(rest.first!)) ?? 0 : 0
        return ClusterChannel(die: die, tier: tier, index: index)
    }

    /// Line IOReport's clusters up with the ones `CPUTopology` found.
    ///
    /// Both sides are ordered lowest logical CPU first: the kernel gives the low
    /// numbers to the low tier, and sorting the channels by tier, then die, then
    /// cluster index reproduces that order. So the pairing is positional, and it
    /// is only offered when both sides count the same number of clusters. A
    /// mismatch means the two views of the chip disagree, and pairing them
    /// anyway would put the performance cluster's frequency on the efficiency
    /// cluster's tile.
    static func pair(channels: [ClusterChannel],
                     with clusters: [CPUTopology.Cluster]) -> [(ClusterChannel, CPUTopology.Cluster)]? {
        guard channels.count == clusters.count else { return nil }
        return Array(zip(channels.sorted(), clusters))
    }
}
