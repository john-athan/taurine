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
/// **Opening is the expensive part.** A tick costs between four and five
/// milliseconds on this M4 Pro, which is the budget ADR 0002 assumed. `open()`
/// costs eighty-five to ninety, nearly all of it inside IOReport's own channel
/// enumeration: every entry point into that library walks the whole IO registry
/// gathering legends, and asking for the three groups one at a time with
/// `IOReportCopyChannelsInGroup` measures at 229 ms against 77 for asking for
/// all ten thousand channels once and throwing most away. There is nothing to
/// optimise on this side of the call, so the cost belongs to whoever decides
/// which thread `open()` happens on.
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

    /// IOReport's own names for the slices we subscribe to. That leaves ten
    /// thousand-odd other channels alone, from Wi-Fi scan counters to spill
    /// buffer histograms, which is what keeps a tick down to the four or five
    /// milliseconds it costs to sample the 293 we do want.
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

    /// Subscribe, read the frequency tables, and take the baseline the first
    /// tick measures against.
    ///
    /// Every step that can throw works on a local, and the probe's own state is
    /// assigned only once all of them have come back. That ordering is the
    /// whole point: `ActivityMonitor` drops a probe whose `open()` threw
    /// without ever calling `close()` on it, so a probe that assigned its
    /// subscription and then threw would hold that subscription, and its mach
    /// port, for as long as the monitor held the probe. Here a throw releases
    /// the local on the way out and leaves the probe exactly as it found it.
    func open() throws {
        let bridge = try IOReportBridge(subscribingTo: [
            .init(Group.energy),
            .init(Group.cpuStats, Group.cpuCoreStates),
            .init(Group.gpuStats, Group.gpuStates),
        ])
        let baseline = try bridge.snapshot()
        let tables = VoltageStates.read()

        close()
        self.bridge = bridge
        self.previous = baseline
        self.voltageStates = tables
    }

    /// Gives back the subscription, the baseline snapshot and every cached
    /// table. Safe twice: everything here is either nil already or assigned nil
    /// again. After this the probe holds no CoreFoundation object at all, which
    /// is the promise on the menu badge.
    ///
    /// There is no `deinit` beside this, because there is nothing for one to
    /// do. Every field below is ARC's, and the subscription that is not lives
    /// inside `IOReportBridge`, which releases it in a deinit of its own. A
    /// probe that is simply dropped therefore gives back exactly what a closed
    /// one does, and the test that says so is not taking anybody's word for it.
    func close() {
        previous = nil
        bridge = nil
        voltageStates = VoltageStates(domains: [:], tables: [])
        clusterFrequencies = [:]
        gpuFrequencies = nil
    }

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
                let states = bridge.residencies(of: item)
                guard let cluster = EnergyArithmetic.clusterChannel(forCoreChannel: item.channel),
                      let fold = EnergyArithmetic.fold(states: states,
                                                       frequenciesMHz: frequencies(for: cluster, states: states))
                else { continue }
                // The first core of a cluster *is* the running total. Seeding
                // with an empty fold would be seeding with a fold that has no
                // frequency, and a missing frequency poisons the sum.
                clusters[cluster] = clusters[cluster].map { $0 + fold } ?? fold

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
    /// Which channel counts as what is `EnergyArithmetic.energyDomain`'s
    /// business, and the note there is worth reading before adding a fifth: the
    /// group nests, so a name matched loosely counts the same watts twice.
    private struct EnergyTotals {
        var cpu: Double?
        var gpuFine: Double?
        var gpuCoarse: Double?
        var ane: Double?

        mutating func absorb(_ item: IOReportBridge.Item, from bridge: IOReportBridge, over seconds: TimeInterval) {
            guard let domain = EnergyArithmetic.energyDomain(ofChannel: item.channel) else { return }
            guard let watts = EnergyArithmetic.watts(energy: bridge.integerValue(of: item),
                                                     unit: item.unit, over: seconds),
                  watts.isFinite, watts >= 0 else { return }

            switch domain {
            case .processor:      cpu = (cpu ?? 0) + watts
            case .graphicsFine:   gpuFine = (gpuFine ?? 0) + watts
            case .graphicsCoarse: gpuCoarse = (gpuCoarse ?? 0) + watts
            case .neural:         ane = (ane ?? 0) + watts
            }
        }

        /// The fine GPU channel wins where both exist, and the coarse one is
        /// the fallback on a chip that publishes no finer one.
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
        guard let operating = EnergyArithmetic.operatingStates(states)?.count else { return [] }
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
        guard let operating = EnergyArithmetic.operatingStates(states)?.count else { return [] }
        let table = voltageStates.frequenciesMHz(operatingStates: operating) ?? []
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
