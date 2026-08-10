import Foundation

/// What VoiceOver is handed.
///
/// The panel draws itself with Core Graphics, so there is no text in the view
/// hierarchy for the accessibility system to discover: these strings are the
/// entire spoken panel. They are checked here because the alternative is
/// checking them by ear, once, on one machine.
func runActivitySpeechTests() {

    func cluster(_ id: String, _ kind: CoreKind, _ cores: [Double],
                 _ mhz: Double? = nil) -> CPUActivity.Cluster {
        CPUActivity.Cluster(id: id, kind: kind, cores: cores, frequencyMHz: mhz, activeResidency: nil)
    }

    Check.suite("speech: cluster names become words") {
        Check.equal(ActivitySpeech.clusterName(cluster("E", .efficiency, [0])),
                    "efficiency cores", "an unsplit level has no index")
        Check.equal(ActivitySpeech.clusterName(cluster("P0", .performance, [0])),
                    "performance cluster 0", "P0 read aloud is meaningless, so it is not read aloud")
        Check.equal(ActivitySpeech.clusterName(cluster("P1", .performance, [0])),
                    "performance cluster 1", "and the index survives")
        Check.equal(ActivitySpeech.clusterName(cluster("P", .performance, [0])),
                    "performance cores", "an Intel chip is one performance level")
    }

    Check.suite("speech: a cluster says its load, its clock and its size") {
        let spoken = ActivitySpeech.cluster(cluster("P0", .performance, [0.5, 0.6, 0.6, 0.5, 0.7], 3840))
        Check.equal(spoken, "performance cluster 0, 58 percent at 3.84 gigahertz, 5 cores",
                    "every unit spelled out")

        let noClock = ActivitySpeech.cluster(cluster("E", .efficiency, [0.1, 0.1, 0.1, 0.1]))
        Check.equal(noClock, "efficiency cores, 10 percent, 4 cores",
                    "an unknown frequency is left out rather than spoken as zero")

        let single = ActivitySpeech.cluster(cluster("P", .performance, [1.0]))
        Check.that(single.hasSuffix("1 core"), "one core is not one cores")
    }

    Check.suite("speech: the processor tile leads with the whole chip") {
        let cpu = CPUActivity(clusters: [cluster("E", .efficiency, [0.1, 0.1, 0.1, 0.1]),
                                         cluster("P", .performance, [0.9, 0.9, 0.9, 0.9])])
        let spoken = ActivitySpeech.cpu(cpu)
        Check.that(spoken.hasPrefix("50 percent busy overall"), "the headline first")
        Check.that(spoken.contains("efficiency cores"), "then each cluster")
        Check.that(spoken.contains("performance cores"), "in order")
        Check.that(spoken.hasSuffix("."), "and it is a sentence")

        Check.equal(ActivitySpeech.cpu(CPUActivity(clusters: [])), "no processor data",
                    "a chip that answered nothing says so")
    }

    Check.suite("speech: graphics") {
        Check.equal(ActivitySpeech.gpu(GPUActivity(utilization: 0.22, frequencyMHz: 1380)),
                    "22 percent busy at 1.38 gigahertz.", "load and clock")
        Check.equal(ActivitySpeech.gpu(GPUActivity(utilization: 0, frequencyMHz: nil)),
                    "0 percent busy.", "and nothing invented when the clock is unknown")
    }

    Check.suite("speech: power leads with the total, then the parts") {
        let full = PowerActivity(cpuWatts: 8.1, gpuWatts: 5.4, aneWatts: 0.07, packageWatts: nil)
        Check.equal(ActivitySpeech.power(full),
                    "13.6 watts total, processor 8.1 watts, graphics 5.4 watts, "
                    + "neural engine 0.07 watts.",
                    "the sum leads, the parts follow, and ANE keeps its two decimals")

        let partial = PowerActivity(cpuWatts: 4.0, gpuWatts: nil, aneWatts: nil, packageWatts: nil)
        Check.equal(ActivitySpeech.power(partial), "4.0 watts total, processor 4.0 watts.",
                    "missing counters are not spoken as zero")

        let none = PowerActivity(cpuWatts: nil, gpuWatts: nil, aneWatts: nil, packageWatts: nil)
        Check.equal(ActivitySpeech.power(none), "no power data", "and a silent chip says so")
    }

    Check.suite("speech: memory mentions swap only when swap is in use") {
        var m = MemoryActivity(used: 19_756_294_144, total: 25_769_803_776,
                               app: 12_988_952_576, wired: 5_153_960_755,
                               compressed: 1_610_612_736, cached: 4_294_967_296,
                               swapUsed: 0, swapTotal: 0)
        let dry = ActivitySpeech.memory(m)
        Check.that(!dry.contains("Swap"), "no swap in use, no swap in the sentence")
        Check.that(dry.contains("18.4 gigabytes of 24.0 gigabytes"), "the headline reads as a sentence")
        Check.that(dry.contains("77 percent"), "with the fraction spelled out")

        m.swapUsed = 1_288_490_188
        m.swapTotal = 4_294_967_296
        Check.that(ActivitySpeech.memory(m).contains("Swap 1.2 gigabytes of 4.0 gigabytes"),
                   "and it appears the moment there is swap to report")
    }

    Check.suite("speech: traffic names its directions") {
        let t = TrafficRate(inboundBytesPerSecond: 4_200_000, outboundBytesPerSecond: 118_000,
                            inboundTotal: 0, outboundTotal: 0)
        Check.equal(ActivitySpeech.traffic(t, inbound: "read", outbound: "written"),
                    "read 4.2 megabytes per second, written 118 kilobytes per second.",
                    "storage reads and writes")
        Check.equal(ActivitySpeech.traffic(t, inbound: "received", outbound: "sent"),
                    "received 4.2 megabytes per second, sent 118 kilobytes per second.",
                    "the network receives and sends")

        let idle = TrafficRate(inboundBytesPerSecond: 0, outboundBytesPerSecond: 0,
                               inboundTotal: 0, outboundTotal: 0)
        Check.that(ActivitySpeech.traffic(idle, inbound: "received", outbound: "sent")
                    .contains("0 bytes per second"), "an idle interface is spoken, not skipped")
    }

    Check.suite("speech: heat is only mentioned when there is heat") {
        Check.isNil(ActivitySpeech.thermal(.nominal), "a cool Mac says nothing about being cool")
        Check.equal(ActivitySpeech.thermal(.fair), "thermal state fair", "fair is named")
        Check.that(ActivitySpeech.thermal(.serious)?.contains("throttling") == true,
                   "serious explains what it means")
        Check.that(ActivitySpeech.thermal(.critical)?.contains("throttling") == true,
                   "and so does critical")
    }

    Check.suite("speech: the footer counts what is missing") {
        Check.isNil(ActivitySpeech.unavailable([]), "nothing missing, nothing said")
        Check.equal(ActivitySpeech.unavailable(["power"]),
                    "One reading is unavailable on this Mac: power.", "singular")
        Check.equal(ActivitySpeech.unavailable(["power", "gpu"]),
                    "2 readings are unavailable on this Mac: power, gpu.", "plural")
    }
}
