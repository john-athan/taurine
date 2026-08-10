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
///     core spent in each DVFS state. The rest states come first and are named
///     (`DOWN`, `IDLE` on the CPU, `OFF` on the GPU); everything after them is
///     an operating point, in the same order as the frequency table from
///     `voltage-states`. The average is weighted by residency over the *active*
///     ticks only, so the answer is "how fast it ran while it ran", not "how
///     fast it ran counting the time it was asleep as zero". Two alignments
///     have to hold and neither is assumed: the rest states have to be a run of
///     names we know at the head of the list, and their count has to leave
///     exactly as many operating points as the frequency table has entries.
///     Either one failing produces nothing rather than a guess.
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

    /// The four energy channels the panel can name, and the total each one's
    /// watts belong in.
    enum EnergyDomain {
        case processor
        /// The plain `GPU` channel, millijoules on this Mac.
        case graphicsCoarse
        /// `GPU Energy`, nanojoules, a million counts to the millijoule
        /// channel's one, which matters at an idle draw of thirty milliwatts.
        case graphicsFine
        case neural
    }

    /// Which total a channel belongs in, by its name with any die prefix off.
    /// Nil for everything else, which is most of the group.
    ///
    /// Every one of the four is matched exactly, with no prefixes anywhere. The
    /// Energy Model group carries 278 channels on this Mac and they nest:
    /// `CPU Energy` rolls up `EACC_CPU`, which rolls up `EACC_CPU0`, and every
    /// one of those has an `_SRAM` twin beside it. A prefix match on "CPU"
    /// would count this chip's processor three times over, and the same trap is
    /// set for the Neural Engine, because the house pattern for a domain's
    /// static RAM is a sibling channel named after it: this chip publishes
    /// `GPU` next to `GPU SRAM`, so a chip publishing `ANE` next to an
    /// `ANE SRAM` would have its Neural Engine, and the panel's total with it,
    /// counted twice by a match on the first three letters. A chip that spells
    /// the channel some other way gets no Neural Engine reading at all, which
    /// is a blank tile rather than a doubled one.
    static func energyDomain(ofChannel channel: String) -> EnergyDomain? {
        switch withoutDiePrefix(channel) {
        case "CPU Energy": return .processor
        case "GPU":        return .graphicsCoarse
        case "GPU Energy": return .graphicsFine
        case "ANE":        return .neural
        default:           return nil
        }
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

    /// The states a residency channel spends *not* running, by the names this
    /// Mac gives them. A CPU core rests in `DOWN` and `IDLE`, the GPU in `OFF`.
    private static let restStateNames: Set<String> = ["DOWN", "IDLE", "OFF"]

    /// The operating points of a residency channel: everything after the rest
    /// states at the head of the list.
    ///
    /// Nil when the names do not divide that way, and that nil is the whole
    /// reason this is a function rather than a filter. Every channel this Mac
    /// publishes rests first and works afterwards (`DOWN, IDLE, V0P6…V6P0` on
    /// an efficiency core, `OFF, P1…P15` on the GPU), so a channel whose first
    /// state is not a rest state we know is a channel whose list we are reading
    /// wrong. Filtering by name instead would quietly count that chip's rest
    /// ticks as work and report every cluster at very nearly 100% busy, which
    /// is a wrong number where the rest of this file produces a silence.
    static func operatingStates(_ states: [IOReportBridge.Residency]) -> ArraySlice<IOReportBridge.Residency>? {
        let rest = states.prefix { restStateNames.contains($0.name) }
        guard !rest.isEmpty else { return nil }
        let operating = states[rest.endIndex...]
        guard !operating.contains(where: { restStateNames.contains($0.name) }) else { return nil }
        return operating
    }

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
        ///
        /// A missing weighted total poisons the sum rather than deferring to
        /// the core that has one. The two numbers the average is made of are
        /// the weighted total and the active ticks, and only the first can go
        /// missing: keeping one core's weighted total next to both cores'
        /// active ticks divides the right numerator by the wrong denominator
        /// and reports a cluster running flat out at 4 GHz as running at 2.
        /// The alignment rule this file states below is exact or nothing, and
        /// that has to survive addition.
        static func + (lhs: Fold, rhs: Fold) -> Fold {
            var sum = Fold()
            sum.activeTicks = lhs.activeTicks + rhs.activeTicks
            sum.totalTicks = lhs.totalTicks + rhs.totalTicks
            if let l = lhs.frequencyWeightedTicks, let r = rhs.frequencyWeightedTicks {
                sum.frequencyWeightedTicks = l + r
            }
            return sum
        }
    }

    /// Fold one channel's states against a frequency table.
    ///
    /// `frequenciesMHz` must already have had its dead leading entries dropped,
    /// so that its first element is the frequency of the first state that is
    /// not a rest state. `VoltageStates` does that trimming, because that is
    /// where the zero-hertz `OFF` row of the GPU table lives.
    ///
    /// Pass an empty table to get residency without a frequency, which is the
    /// honest answer on a machine whose `voltage-states` we could not read.
    /// Nil comes back only when the states themselves cannot be divided into
    /// rest and work, and then there is no residency to report either.
    static func fold(states: [IOReportBridge.Residency], frequenciesMHz: [Double]) -> Fold? {
        guard let operating = operatingStates(states) else { return nil }

        var fold = Fold()
        for state in states { fold.totalTicks += Double(max(0, state.ticks)) }
        let operatingTicks = operating.map { Double(max(0, $0.ticks)) }
        fold.activeTicks = operatingTicks.reduce(0, +)

        // Alignment is the only thing that can silently produce a wrong number,
        // so it has to be exact or nothing.
        guard !frequenciesMHz.isEmpty, operatingTicks.count == frequenciesMHz.count else {
            return fold
        }
        fold.frequencyWeightedTicks = zip(operatingTicks, frequenciesMHz).reduce(0) { $0 + $1.0 * $1.1 }
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
