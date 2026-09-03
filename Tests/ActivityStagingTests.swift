import Foundation

/// The seam between the probes.
///
/// One probe in the app writes onto what another one produced, and writes
/// nothing at all if it runs first. That used to be a matter of list order,
/// which nothing enforced and no test noticed breaking: reordering the list
/// left every existing suite green and quietly took every clock reading off the
/// panel. These checks are what make that impossible now.
func runActivityStagingTests() {

    /// Writes a section, and says when it ran.
    final class Producer: ActivityProbe {
        let name = "producer"
        let order: Order
        init(_ order: Order) { self.order = order }
        func open() throws {}
        func close() {}
        func read(into sample: inout ActivitySample) {
            order.ran.append(name)
            sample.gpu = GPUActivity(utilization: 0.5, frequencyMHz: nil)
        }
    }

    /// Adds to that section, and can only do so if it is already there.
    final class Enricher: ActivityProbe {
        let name = "enricher"
        let stage = ProbeStage.enrich
        let order: Order
        init(_ order: Order) { self.order = order }
        func open() throws {}
        func close() {}
        func read(into sample: inout ActivitySample) {
            order.ran.append(name)
            sample.gpu?.frequencyMHz = 1234
        }
    }

    final class Order { var ran: [String] = [] }

    /// Run one sample through a monitor built from `probes`, and hand back what
    /// came out and in which order the probes ran.
    func session(_ probes: [ActivityProbe], _ order: Order) -> ActivitySample? {
        let monitor = ActivityMonitor(probes: probes)
        var last: ActivitySample?
        monitor.onSample = { last = $0 }
        monitor.start(interval: 0.1)
        let deadline = Date().addingTimeInterval(3)
        while last == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        monitor.stop()
        return last
    }

    Check.suite("staging: an enricher runs last however it is listed") {
        for (label, probes) in [("enricher first", 0), ("enricher last", 1)] {
            let order = Order()
            let producer = Producer(order), enricher = Enricher(order)
            let list: [ActivityProbe] = probes == 0 ? [enricher, producer] : [producer, enricher]
            guard let sample = Check.unwrap(session(list, order), "\(label): a sample arrived") else { continue }
            // The first sample's two entries, not the whole list. The monitor
            // ticks every 0.1s and the loop above notices in 0.02s slices, so a
            // second sample can land before the wait returns and `order.ran`
            // then holds four entries. What this suite is about is the order
            // within a sample, which the first two answer; on a GitHub runner
            // the exact-equality version failed every time, and on a busy Mac
            // it would have failed eventually.
            Check.equal(Array(order.ran.prefix(2)), ["producer", "enricher"],
                        "\(label): the producer still ran first")
            Check.equal(sample.gpu?.frequencyMHz, 1234, "\(label): the enrichment landed")
        }
    }

    Check.suite("staging: the app's own probes declare themselves") {
        let probes = ActivityProbes.standard()
        Check.equal(probes.filter { $0.stage == .enrich }.map(\.name), ["energy"],
                    "energy is the only probe that decorates somebody else's section")
        Check.that(probes.contains { $0.name == "processor" } && probes.contains { $0.name == "graphics" },
                   "and the two sections it decorates are both produced")
    }

    Check.suite("staging: this Mac fills in what the energy probe adds") {
        // The live version of the same contract: on a machine where IOReport
        // answers, the clusters the processor probe built come back with the
        // frequencies the energy probe wrote onto them.
        let order = Order()
        guard let sample = Check.unwrap(session(ActivityProbes.standard(), order),
                                        "a sample arrived from the real probes") else { return }
        guard let cpu = sample.cpu else {
            Check.that(false, "the processor probe produced its section")
            return
        }
        if sample.unavailable.contains(where: { $0.name == "energy" }) {
            Check.that(sample.power == nil, "an energy probe that declined leaves no power behind")
            return
        }
        Check.that(cpu.clusters.contains { $0.activeResidency != nil },
                   "at least one cluster carries the residency the energy probe wrote")
        Check.that(sample.power?.cpuWatts != nil, "and the watts arrived with it")
    }
}
