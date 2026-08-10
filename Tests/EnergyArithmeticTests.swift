import Foundation

/// The parts of a power reading that can be wrong rather than merely absent.
///
/// None of this needs a Mac: an energy counter is an integer, a unit is a
/// string, a residency table is a list of pairs. Which is exactly why the
/// arithmetic was pulled out of the probe in the first place, and why these
/// tests can describe chips this machine is not.
func runEnergyArithmeticTests() {

    func states(_ pairs: [(String, Int64)]) -> [IOReportBridge.Residency] {
        pairs.map { IOReportBridge.Residency(name: $0.0, ticks: $0.1) }
    }

    Check.suite("energy: unit labels this Mac actually reports") {
        // All three appear in one group on an M4 Pro: mJ for the CPU, nJ for
        // the GPU, uJ for the PCIe ports.
        Check.equal(EnergyArithmetic.joulesPerCount("mJ"), 1e-3, "millijoules")
        Check.equal(EnergyArithmetic.joulesPerCount("uJ"), 1e-6, "microjoules, ASCII spelling")
        Check.equal(EnergyArithmetic.joulesPerCount("µJ"), 1e-6, "microjoules, real micro sign")
        Check.equal(EnergyArithmetic.joulesPerCount("nJ"), 1e-9, "nanojoules")
        Check.equal(EnergyArithmetic.joulesPerCount(" mJ "), 1e-3, "padding does not change the unit")
    }

    Check.suite("energy: an unrecognised unit is silence, not a guess") {
        Check.isNil(EnergyArithmetic.joulesPerCount("24Mticks"), "a residency unit is not an energy unit")
        Check.isNil(EnergyArithmetic.joulesPerCount(""), "an unlabelled channel")
        Check.isNil(EnergyArithmetic.joulesPerCount("Wh"), "a unit we have never seen")
        Check.isNil(EnergyArithmetic.watts(energy: 1_000_000, unit: "pJ", over: 1),
                    "watts declines rather than assuming a scale")
    }

    Check.suite("energy: counter delta to watts") {
        // 1957 mJ over one second is the CPU figure this Mac reported while a
        // build was running.
        Check.close(EnergyArithmetic.watts(energy: 1957, unit: "mJ", over: 1) ?? 0,
                    1.957, tolerance: 1e-9, "millijoules over a second")
        Check.close(EnergyArithmetic.watts(energy: 70_515_285, unit: "nJ", over: 1.0) ?? 0,
                    0.070515285, tolerance: 1e-9, "the GPU's nanojoule channel")
        // The window is whatever the two snapshots were actually apart, never
        // the interval anybody asked for.
        Check.close(EnergyArithmetic.watts(energy: 1_000_000, unit: "uJ", over: 0.2505) ?? 0,
                    3.992016, tolerance: 1e-6, "an interval that is not a round number")
        Check.equal(EnergyArithmetic.watts(energy: 0, unit: "mJ", over: 1), 0, "an idle domain reads zero")
    }

    Check.suite("energy: an interval you cannot divide by") {
        Check.isNil(EnergyArithmetic.watts(energy: 500, unit: "mJ", over: 0), "the first tick of a session")
        Check.isNil(EnergyArithmetic.watts(energy: 500, unit: "mJ", over: -1), "a clock that went backwards")
    }

    Check.suite("energy: the die prefix comes off before the name is matched") {
        Check.equal(EnergyArithmetic.withoutDiePrefix("DIE_1_CPU Energy"), "CPU Energy", "an Ultra's second die")
        Check.equal(EnergyArithmetic.withoutDiePrefix("DIE_0_GPU Energy"), "GPU Energy", "an Ultra's first die")
        Check.equal(EnergyArithmetic.withoutDiePrefix("CPU Energy"), "CPU Energy", "a single-die chip is untouched")
        Check.equal(EnergyArithmetic.withoutDiePrefix("DIE_X_CPU"), "DIE_X_CPU", "DIE_ without a number is a name")
        Check.equal(EnergyArithmetic.withoutDiePrefix("DIEHARD"), "DIEHARD", "and so is a word that starts the same")
    }

    Check.suite("residency: a cluster that ran half the interval") {
        // The shape an M4 Pro efficiency core reports: two rest states first,
        // then one operating point per entry in voltage-states1-sram.
        let fold = EnergyArithmetic.fold(
            states: states([("DOWN", 0), ("IDLE", 500), ("V0P1", 100), ("V1P0", 400)]),
            frequenciesMHz: [1000, 2000])
        Check.close(fold.activeResidency ?? -1, 0.5, tolerance: 1e-12, "half the ticks were operating ticks")
        // Weighted over the active ticks only: (100·1000 + 400·2000) / 500.
        Check.close(fold.frequencyMHz ?? -1, 1800, tolerance: 1e-9, "residency-weighted mean while running")
    }

    Check.suite("residency: a cluster that never woke up") {
        let fold = EnergyArithmetic.fold(
            states: states([("DOWN", 800), ("IDLE", 200), ("V0P1", 0), ("V1P0", 0)]),
            frequenciesMHz: [1000, 2000])
        Check.equal(fold.activeResidency, 0, "zero residency is a number, and it is zero")
        Check.isNil(fold.frequencyMHz, "there is no average frequency of nothing")
    }

    Check.suite("residency: power-gated time counts against the interval") {
        // DOWN is a core the scheduler switched off, not a core that was busy.
        let fold = EnergyArithmetic.fold(
            states: states([("DOWN", 900), ("IDLE", 0), ("V0P0", 100)]),
            frequenciesMHz: [3000])
        Check.close(fold.activeResidency ?? -1, 0.1, tolerance: 1e-12, "one tick in ten")
        Check.close(fold.frequencyMHz ?? -1, 3000, tolerance: 1e-9, "and it ran flat out for that tick")
    }

    Check.suite("residency: the GPU rests in OFF, not IDLE") {
        let fold = EnergyArithmetic.fold(
            states: states([("OFF", 750), ("P1", 250), ("P2", 0)]),
            frequenciesMHz: [338, 618])
        Check.close(fold.activeResidency ?? -1, 0.25, tolerance: 1e-12, "a quarter of the interval")
        Check.close(fold.frequencyMHz ?? -1, 338, tolerance: 1e-9, "at the bottom of its table")
    }

    Check.suite("residency: a table that does not fit is refused") {
        let mismatched = EnergyArithmetic.fold(
            states: states([("IDLE", 100), ("V0", 100), ("V1", 100), ("V2", 100)]),
            frequenciesMHz: [1000, 2000])
        Check.close(mismatched.activeResidency ?? -1, 0.75, tolerance: 1e-12,
                    "residency survives, it needs no table")
        Check.isNil(mismatched.frequencyMHz, "but a misaligned table produces no frequency at all")

        let tableless = EnergyArithmetic.fold(
            states: states([("IDLE", 500), ("V0", 500)]), frequenciesMHz: [])
        Check.close(tableless.activeResidency ?? -1, 0.5, tolerance: 1e-12, "same on a Mac with no voltage-states")
        Check.isNil(tableless.frequencyMHz, "and still no invented number")

        let empty = EnergyArithmetic.fold(states: [], frequenciesMHz: [1000])
        Check.isNil(empty.activeResidency, "a channel that reported nothing has no residency either")
    }

    Check.suite("residency: cores add up before they divide") {
        // Two cores of one cluster, one busy and one asleep. Averaging their
        // percentages would say 50%; summing their ticks says 50% too, but the
        // frequency has to come only from the core that actually ran.
        let busy = EnergyArithmetic.fold(states: states([("IDLE", 0), ("V0", 1000)]), frequenciesMHz: [4000])
        let asleep = EnergyArithmetic.fold(states: states([("IDLE", 1000), ("V0", 0)]), frequenciesMHz: [4000])
        let cluster = busy + asleep
        Check.close(cluster.activeResidency ?? -1, 0.5, tolerance: 1e-12, "half the cluster's ticks were work")
        Check.close(cluster.frequencyMHz ?? -1, 4000, tolerance: 1e-9,
                    "the sleeping core does not drag the frequency down")
    }

    Check.suite("channels: the three shapes IOReport uses for a core") {
        func cluster(_ name: String) -> EnergyArithmetic.ClusterChannel? {
            EnergyArithmetic.clusterChannel(forCoreChannel: name)
        }

        // M4 Pro, verified on this machine: ECPU000…ECPU030, PCPU000…PCPU040,
        // PCPU100…PCPU140.
        Check.equal(cluster("ECPU000")?.domainName, "ECPU", "first efficiency core")
        Check.equal(cluster("ECPU030")?.domainName, "ECPU", "fourth efficiency core, same cluster")
        Check.equal(cluster("PCPU040")?.domainName, "PCPU", "fifth core of the first performance cluster")
        Check.equal(cluster("PCPU140")?.domainName, "PCPU1", "fifth core of the second one")
        Check.equal(cluster("PCPU100")?.index, 1, "the leading digit is the cluster, not the core")

        // A lone digit is a core number on a chip whose tier is one cluster.
        Check.equal(cluster("PCPU7")?.index, 0, "a single digit cannot be a cluster")
        Check.equal(cluster("ECPU7")?.tier, .efficiency, "and it is still an efficiency channel")

        // M5 Pro and Max: a genuine middle tier rather than a renamed E cluster.
        Check.equal(cluster("MCPU3")?.tier, .middle, "MCPU is its own rung")

        Check.isNil(cluster("GPUPH"), "the GPU's channel is not a CPU core")
        Check.isNil(cluster("CPU Energy"), "neither is an energy channel")
        Check.isNil(cluster("PCPU"), "nor a complex channel with no core on it")
    }

    Check.suite("channels: an Ultra's die prefix is not a core number") {
        func cluster(_ name: String) -> EnergyArithmetic.ClusterChannel? {
            EnergyArithmetic.clusterChannel(forCoreChannel: name)
        }

        Check.equal(cluster("DIE_1_PCPU1_CPU0")?.die, 1, "die one")
        Check.equal(cluster("DIE_1_PCPU1_CPU0")?.index, 1, "second performance cluster on it")
        Check.equal(cluster("DIE_1_PCPU1_CPU0")?.tier, .performance, "and it is a performance cluster")
        Check.equal(cluster("DIE_0_PCPU_CPU3")?.index, 0, "an empty cluster number means cluster zero")
        Check.equal(cluster("DIE_0_ECPU_CPU1")?.domainName, "ECPU", "the die drops out of the domain name")
        Check.equal(cluster("DIE_2_ECPU_CPU1")?.dieQualifiedDomainName, "DIE_2_ECPU",
                    "and back in for chips that publish domains per die")
        Check.isNil(cluster("DIE_X_PCPU0"), "DIE_ with no number is not a die prefix")

        // The mistake this all exists to prevent.
        Check.that(cluster("DIE_1_PCPU_CPU0") != cluster("DIE_0_PCPU_CPU0"),
                   "two dies' first performance clusters are different clusters")
    }

    Check.suite("channels: pairing an M4 Pro with its topology") {
        let topology = CPUTopology.compose(levels: [
            .init(name: "Performance", logicalCPUs: 10, coresPerL2: 5),
            .init(name: "Efficiency", logicalCPUs: 4, coresPerL2: 4),
        ])
        // Dictionary order is not a thing, so the channels arrive shuffled.
        let channels = ["PCPU140", "ECPU000", "PCPU040"].compactMap {
            EnergyArithmetic.clusterChannel(forCoreChannel: $0)
        }
        let paired = Check.unwrap(EnergyArithmetic.pair(channels: channels, with: topology.clusters),
                                  "three clusters on each side pair up")
        Check.equal(paired?.map { $0.1.id } ?? [], ["E", "P0", "P1"], "topology side keeps its order")
        Check.equal(paired?.map { $0.0.domainName } ?? [], ["ECPU", "PCPU", "PCPU1"],
                    "channel side sorts into the same order")
    }

    Check.suite("channels: pairing an Ultra puts both dies' E clusters first") {
        // An M1 Ultra numbers cpu0…cpu3 as the efficiency cores of *both* dies,
        // so the channel order has to be tier before die.
        let topology = CPUTopology.compose(levels: [
            .init(name: "Performance", logicalCPUs: 16, coresPerL2: 4),
            .init(name: "Efficiency", logicalCPUs: 4, coresPerL2: 2),
        ])
        let channels = ["DIE_1_PCPU1_CPU0", "DIE_0_ECPU_CPU0", "DIE_1_PCPU_CPU0",
                        "DIE_0_PCPU1_CPU0", "DIE_1_ECPU_CPU0", "DIE_0_PCPU_CPU0"]
            .compactMap { EnergyArithmetic.clusterChannel(forCoreChannel: $0) }
        let paired = Check.unwrap(EnergyArithmetic.pair(channels: channels, with: topology.clusters),
                                  "six clusters on each side pair up")
        Check.equal(paired?.map { $0.1.id } ?? [], ["E0", "E1", "P0", "P1", "P2", "P3"], "topology order")
        Check.equal(paired?.map { "\($0.0.die)/\($0.0.domainName)" } ?? [],
                    ["0/ECPU", "1/ECPU", "0/PCPU", "0/PCPU1", "1/PCPU", "1/PCPU1"],
                    "efficiency clusters of both dies come before any performance cluster")
    }

    Check.suite("channels: a disagreement about the chip is not papered over") {
        let topology = CPUTopology.compose(levels: [
            .init(name: "Performance", logicalCPUs: 10, coresPerL2: 5),
            .init(name: "Efficiency", logicalCPUs: 4, coresPerL2: 4),
        ])
        let two = ["ECPU000", "PCPU040"].compactMap { EnergyArithmetic.clusterChannel(forCoreChannel: $0) }
        Check.isNil(EnergyArithmetic.pair(channels: two, with: topology.clusters),
                    "two channel clusters against three topology clusters pairs nothing")
        Check.isNil(EnergyArithmetic.pair(channels: [], with: topology.clusters),
                    "and neither does none")
    }
}
