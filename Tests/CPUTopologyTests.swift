import Foundation

/// Chip shapes, real and hypothetical.
///
/// The interesting cases are chips this Mac is not, which is exactly why
/// `CPUTopology.compose` takes its levels as an argument instead of reading
/// sysctl itself.
func runCPUTopologyTests() {

    Check.suite("topology: M4 Pro (4E + 10P in two L2 groups)") {
        let t = CPUTopology.compose(levels: [
            .init(name: "Performance", logicalCPUs: 10, coresPerL2: 5),
            .init(name: "Efficiency", logicalCPUs: 4, coresPerL2: 4),
        ])
        Check.equal(t.clusters.count, 3, "one efficiency cluster and two performance clusters")
        Check.equal(t.coreCount, 14, "every core accounted for")
        Check.equal(t.clusters.map(\.id), ["E", "P0", "P1"], "cluster identities")
        Check.equal(t.clusters[0].coreIDs, [0, 1, 2, 3], "efficiency cores hold the low CPU numbers")
        Check.equal(t.clusters[1].coreIDs, [4, 5, 6, 7, 8], "first performance cluster")
        Check.equal(t.clusters[2].coreIDs, [9, 10, 11, 12, 13], "second performance cluster")
        Check.equal(t.clusters[0].kind, .efficiency, "low cores are the efficiency level")
    }

    Check.suite("topology: M1 (4E + 4P, single performance cluster)") {
        let t = CPUTopology.compose(levels: [
            .init(name: "Performance", logicalCPUs: 4, coresPerL2: 4),
            .init(name: "Efficiency", logicalCPUs: 4, coresPerL2: 4),
        ])
        Check.equal(t.clusters.map(\.id), ["E", "P"], "no index suffix when a level is one cluster")
        Check.equal(t.clusters[1].coreIDs, [4, 5, 6, 7], "performance cores follow the efficiency cores")
    }

    Check.suite("topology: M1 Ultra (4 clusters of performance cores)") {
        let t = CPUTopology.compose(levels: [
            .init(name: "Performance", logicalCPUs: 16, coresPerL2: 4),
            .init(name: "Efficiency", logicalCPUs: 4, coresPerL2: 2),
        ])
        Check.equal(t.clusters.map(\.id), ["E0", "E1", "P0", "P1", "P2", "P3"], "both levels split")
        Check.equal(t.coreCount, 20, "every core accounted for")
        Check.equal(t.clusters.last?.coreIDs ?? [], [16, 17, 18, 19], "last cluster closes the range")
    }

    Check.suite("topology: Intel, one performance level") {
        let t = CPUTopology.compose(levels: [
            .init(name: "Performance", logicalCPUs: 8, coresPerL2: 0),
        ])
        Check.equal(t.clusters.count, 1, "a chip without efficiency cores is one cluster")
        Check.equal(t.clusters[0].coreIDs.count, 8, "hyperthreads included")
        Check.equal(t.clusters[0].kind, .performance, "and it is the performance kind")
    }

    Check.suite("topology: a chip that answers nothing") {
        let t = CPUTopology.compose(levels: [])
        Check.that(!t.clusters.isEmpty, "still produces a cluster")
        Check.that(t.coreCount >= 1, "with at least one core")
    }

    Check.suite("topology: an odd L2 group divides without losing cores") {
        let t = CPUTopology.compose(levels: [
            .init(name: "Performance", logicalCPUs: 6, coresPerL2: 4),
        ])
        Check.equal(t.coreCount, 6, "no core invented, none dropped")
        Check.equal(t.clusters.map(\.coreIDs.count), [4, 2], "the remainder is its own cluster")
    }

    Check.suite("topology: this Mac") {
        let t = CPUTopology.current
        Check.equal(t.coreCount, Int(CPUTopology.sysctlInt("hw.logicalcpu") ?? -1),
                    "detected core count matches the kernel")
        Check.that(t.clusters.allSatisfy { !$0.coreIDs.isEmpty }, "no empty clusters")
        let ids = t.clusters.flatMap(\.coreIDs)
        Check.equal(ids, Array(0..<ids.count), "core numbers are contiguous and ordered")
    }
}
