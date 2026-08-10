import Foundation

/// The wattmeter. ⚡
///
/// The one probe that answers a question no public API answers: how many watts
/// this chip is burning, and how fast each cluster is actually clocked. It runs
/// after the processor probe and writes onto the clusters that probe built, so
/// the panel gets busy-fraction, frequency and active residency on one row.
///
/// Three things about the shape of this file.
///
/// **Everything is a difference.** IOReport's energy channels are odometers,
/// not speedometers. A single reading is meaningless; a pair of readings and
/// the seconds between them is a watt. So the probe keeps exactly one snapshot
/// between ticks, takes its baseline in `open()` (which is the cost ADR 0002
/// says the person who opened the panel pays), and hands back nothing on any
/// tick whose window is too short to divide by. That is why the first frame of
/// a session has no power tile.
///
/// **Nothing is assumed about units.** This Mac reports `mJ` for the CPU, `nJ`
/// for the GPU and `uJ` for the PCIe ports, all inside one group. The label on
/// the channel is the only authority, and an unfamiliar label produces no
/// reading at all rather than a reading that is off by a million.
///
/// **Opening is the expensive part.** A tick costs about five milliseconds on
/// an M4 Pro, which is the budget ADR 0002 assumed. `open()` costs about
/// seventy-five, nearly all of it inside IOReport's own channel enumeration:
/// every entry point into that library walks the whole IO registry gathering
/// legends, and asking for three named groups one at a time measures slower
/// than asking for all ten thousand channels once and throwing most away. There
/// is nothing to optimise on this side of the call, so the cost belongs to
/// whoever decides which thread `open()` happens on.
///
/// **`packageWatts` stays nil, on purpose.** This chip publishes no
/// package-level energy channel: it publishes `CPU Energy`, `GPU Energy`,
/// `ANE`, `DRAM`, `DCS`, `AMCC`, `DISP` and a dozen more, plus the per-core
/// counters those roll up from. Adding a hand-picked subset of them together
/// and calling the answer "package power" would invent a number, and picking
/// wrong is easy: `GPU` and `GPU Energy` are the same watts reported twice at
/// different resolutions. `PowerActivity.totalWatts` already falls back to the
/// sum of the parts we can name, and that sum is honest.
final class EnergyProbe: ActivityProbe {

    let name = "energy"

    /// IOReport's own names for the slices we subscribe to. Everything else on
    /// this Mac (some nine and a half thousand channels, from Wi-Fi scan
    /// counters to spill buffer histograms) is left alone, which is what keeps
    /// a tick down to a couple of milliseconds.
    private enum Group {
        static let energy = "Energy Model"
        static let cpuStats = "CPU Stats"
        static let cpuCoreStates = "CPU Core Performance States"
        static let gpuStats = "GPU Stats"
        static let gpuStates = "GPU Performance States"
        /// The GPU's own performance-state channel. Its siblings in the same
        /// subgroup describe the boost controller and the thermal limiter, not
        /// the clock.
        static let gpuChannel = "GPUPH"
    }

    /// Shortest window worth dividing by. The coarsest energy channel counts in
    /// millijoules, so at a plausible idle draw a fiftieth of a second still
    /// carries enough counts to be worth a number. Anything shorter, and the
    /// quantisation *is* the reading.
    private static let shortestInterval: TimeInterval = 0.05

    private var bridge: IOReportBridge?
    private var previous: IOReportBridge.Snapshot?
    private var voltageStates = VoltageStates(domains: [:], tables: [])
    /// Frequency tables, resolved on first sight of a cluster and kept until
    /// close. The registry lookup behind them is stable for the life of the
    /// machine; doing it once per second would be a waste.
    private var clusterFrequencies: [EnergyArithmetic.ClusterChannel: [Double]] = [:]
    private var gpuFrequencies: [Double]?

    // MARK: - lifecycle

    func open() throws {
        let bridge = try IOReportBridge(subscribingTo: [
            .init(Group.energy),
            .init(Group.cpuStats, Group.cpuCoreStates),
            .init(Group.gpuStats, Group.gpuStates),
        ])
        self.bridge = bridge
        self.voltageStates = VoltageStates.read()
        self.previous = try bridge.snapshot()
    }

    /// Gives back the subscription, the baseline snapshot and every cached
    /// table. Safe twice: everything here is either nil already or assigned nil
    /// again. After this the probe holds no CoreFoundation object at all, which
    /// is the promise on the menu badge.
    func close() {
        previous = nil
        bridge = nil
        voltageStates = VoltageStates(domains: [:], tables: [])
        clusterFrequencies = [:]
        gpuFrequencies = nil
    }

    deinit { close() }

    // MARK: - reading

    func read(into sample: inout ActivitySample) {
        guard let bridge, let baseline = previous else { return }
        guard let now = try? bridge.snapshot() else { return }

        let elapsed = now.uptime - baseline.uptime
        guard elapsed >= Self.shortestInterval else {
            // Keep the old baseline. The next tick then measures from it and
            // gets a window long enough to mean something, instead of us
            // resetting the clock every time and never producing a reading.
            return
        }
        guard let items = try? bridge.difference(from: baseline, to: now) else {
            previous = now
            return
        }
        previous = now

        var energy = EnergyTotals()
        var clusters: [EnergyArithmetic.ClusterChannel: EnergyArithmetic.Fold] = [:]
        var gpu: EnergyArithmetic.Fold?

        for item in items {
            switch (item.group, item.subgroup) {
            case (Group.energy, _):
                energy.absorb(item, from: bridge, over: elapsed)

            case (Group.cpuStats, Group.cpuCoreStates):
                guard let cluster = EnergyArithmetic.clusterChannel(forCoreChannel: item.channel) else { continue }
                let states = bridge.residencies(of: item)
                let table = frequencies(for: cluster, states: states)
                let fold = EnergyArithmetic.fold(states: states, frequenciesMHz: table)
                clusters[cluster] = (clusters[cluster] ?? EnergyArithmetic.Fold()) + fold

            case (Group.gpuStats, Group.gpuStates) where item.channel == Group.gpuChannel:
                let states = bridge.residencies(of: item)
                gpu = EnergyArithmetic.fold(states: states, frequenciesMHz: gpuFrequencies(for: states))

            default:
                continue
            }
        }

        sample.power = energy.activity
        apply(clusters, to: &sample)
        if let gpu, sample.gpu != nil {
            sample.gpu?.frequencyMHz = gpu.frequencyMHz
        }
    }

    // MARK: - energy

    /// The energy channels we know how to name, summed across dies.
    ///
    /// Matching is on the channel name with any `DIE_n_` prefix removed, and it
    /// is exact rather than fuzzy for a reason: the same group also carries
    /// `EACC_CPU`, `PACC0_CPU` and `EACC_CPU0`, which are the cluster and
    /// per-core counters that `CPU Energy` already rolls up. A prefix match on
    /// "CPU" would count this chip's processor three times over.
    private struct EnergyTotals {
        var cpu: Double?
        /// The `GPU Energy` channel, nanojoules on this Mac. A million counts
        /// to the millijoule channel's one, which matters at an idle draw of
        /// thirty milliwatts.
        var gpuFine: Double?
        /// The plain `GPU` channel, millijoules, and the fallback on a chip
        /// that publishes no finer one.
        var gpuCoarse: Double?
        var ane: Double?

        mutating func absorb(_ item: IOReportBridge.Item, from bridge: IOReportBridge, over seconds: TimeInterval) {
            let channel = EnergyArithmetic.withoutDiePrefix(item.channel)
            guard channel == "CPU Energy" || channel == "GPU Energy" || channel == "GPU"
                    || channel.hasPrefix("ANE") else { return }
            guard let watts = EnergyArithmetic.watts(energy: bridge.integerValue(of: item),
                                                     unit: item.unit, over: seconds),
                  watts.isFinite, watts >= 0 else { return }

            switch channel {
            case "CPU Energy": cpu = (cpu ?? 0) + watts
            case "GPU Energy": gpuFine = (gpuFine ?? 0) + watts
            case "GPU":        gpuCoarse = (gpuCoarse ?? 0) + watts
            default:           ane = (ane ?? 0) + watts
            }
        }

        var activity: PowerActivity? {
            let power = PowerActivity(cpuWatts: cpu,
                                      gpuWatts: gpuFine ?? gpuCoarse,
                                      aneWatts: ane,
                                      packageWatts: nil)
            return power.totalWatts == nil ? nil : power
        }
    }

    // MARK: - frequency tables

    /// The megahertz behind one cluster's operating states.
    ///
    /// Asked for by the name the machine itself uses (`ECPU`, `PCPU`, `PCPU1`),
    /// with the die-qualified spelling tried first for chips that publish their
    /// domains per die. Falling back to matching on the number of operating
    /// states covers a chip whose `perf-domains` table we could not read, and
    /// that fallback only answers when every candidate of the right shape says
    /// the same thing.
    private func frequencies(for cluster: EnergyArithmetic.ClusterChannel,
                             states: [IOReportBridge.Residency]) -> [Double] {
        if let cached = clusterFrequencies[cluster] { return cached }
        let operating = EnergyArithmetic.operatingStateCount(states)
        let table = voltageStates.frequenciesMHz(domain: [cluster.dieQualifiedDomainName, cluster.domainName],
                                                 operatingStates: operating)
            ?? voltageStates.frequenciesMHz(operatingStates: operating)
            ?? []
        clusterFrequencies[cluster] = table
        return table
    }

    /// The GPU's table. `perf-domains` on this Mac names every power domain
    /// except the graphics one, so shape is all there is to go on.
    private func gpuFrequencies(for states: [IOReportBridge.Residency]) -> [Double] {
        if let cached = gpuFrequencies { return cached }
        let table = voltageStates.frequenciesMHz(operatingStates: EnergyArithmetic.operatingStateCount(states)) ?? []
        gpuFrequencies = table
        return table
    }

    // MARK: - writing back

    /// Put each cluster's frequency and residency onto the cluster the
    /// processor probe already built, matched by identity.
    ///
    /// If the two sides count a different number of clusters, nothing is
    /// written. A partial alignment is worse than none: it would print the
    /// performance cores' 4.5 GHz next to the efficiency cores' core count and
    /// nobody would be able to tell.
    private func apply(_ folds: [EnergyArithmetic.ClusterChannel: EnergyArithmetic.Fold],
                       to sample: inout ActivitySample) {
        guard var cpu = sample.cpu, !folds.isEmpty else { return }
        guard let pairs = EnergyArithmetic.pair(channels: Array(folds.keys),
                                                with: CPUTopology.current.clusters) else { return }

        for (channel, topology) in pairs {
            guard let fold = folds[channel],
                  let index = cpu.clusters.firstIndex(where: { $0.id == topology.id }) else { continue }
            cpu.clusters[index].frequencyMHz = fold.frequencyMHz
            cpu.clusters[index].activeResidency = fold.activeResidency
        }
        sample.cpu = cpu
    }
}
