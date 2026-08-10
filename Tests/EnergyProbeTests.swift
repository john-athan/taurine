import Foundation

/// The probe against the machine it is running on. 🔌
///
/// The arithmetic is tested elsewhere, without hardware. What is left is
/// everything that only reality can answer: whether the private framework still
/// exists, whether the numbers that come out of it are the right order of
/// magnitude, whether they move when the machine works, and whether closing the
/// panel really does give everything back.
///
/// These are deliberately loose. Asserting a specific wattage would fail on
/// every Mac but the one it was written on; asserting that a saturated chip
/// draws more than an idle one is true of all of them.
func runEnergyProbeTests() {

    // An Intel Mac has no energy model to read, and `open()` throwing is the
    // supported way for the probe to say so. That is worth a test of its own
    // rather than a skip.
    guard (CPUTopology.sysctlInt("hw.optional.arm64") ?? 0) == 1 else {
        Check.suite("energy: a Mac with no energy model") {
            Check.throwsError("the probe declines to open rather than reporting zeros") {
                try EnergyProbe().open()
            }
        }
        return
    }

    /// A sample shaped the way the processor and GPU probes leave it, so the
    /// energy probe has clusters to enrich.
    func blank() -> ActivitySample {
        var sample = ActivitySample(uptime: ProcessInfo.processInfo.systemUptime, interval: 1)
        sample.cpu = CPUActivity(clusters: CPUTopology.current.clusters.map {
            CPUActivity.Cluster(id: $0.id, kind: $0.kind,
                                cores: Array(repeating: 0, count: $0.coreIDs.count))
        })
        sample.gpu = GPUActivity(utilization: 0, frequencyMHz: nil)
        return sample
    }

    func reading(after seconds: TimeInterval, from probe: EnergyProbe) -> ActivitySample {
        Thread.sleep(forTimeInterval: seconds)
        var sample = blank()
        probe.read(into: &sample)
        return sample
    }

    /// Saturate every core for a while, and take a reading during it.
    func underLoad(for seconds: TimeInterval, _ body: () -> ActivitySample) -> ActivitySample {
        let deadline = Date().addingTimeInterval(seconds)
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            Thread.detachNewThread {
                var accumulator = SIMD8<Double>(repeating: 1.000001)
                let multiplier = SIMD8<Double>(repeating: 1.0000001)
                let addend = SIMD8<Double>(repeating: 0.0000001)
                while Date() < deadline {
                    for _ in 0..<50_000 { accumulator = accumulator * multiplier + addend }
                }
                // Keeps the loop from being reasoned away, and never prints.
                if accumulator.sum() == 0 { print("") }
            }
        }
        return body()
    }

    /// What the kernel says this process is costing in physical memory.
    func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    let probe = EnergyProbe()
    var opened = false

    Check.suite("energy: the private framework is still there") {
        do {
            try probe.open()
            opened = true
        } catch {
            Check.that(false, "the probe opens on an Apple Silicon Mac (\(error))")
        }
    }
    guard opened else { return }
    defer { probe.close() }

    Check.suite("energy: a window too short to divide by yields nothing") {
        // The baseline was taken microseconds ago in open(). Millijoule
        // counters over a window that short are quantisation, not a reading.
        var immediate = blank()
        probe.read(into: &immediate)
        Check.isNil(immediate.power, "no power tile on the first frame of a session")
    }

    let idle = reading(after: 0.4, from: probe)

    Check.suite("energy: an unloaded chip draws a plausible number of watts") {
        guard let power = Check.unwrap(idle.power, "the power section is filled in") else { return }
        guard let cpu = Check.unwrap(power.cpuWatts, "the CPU energy channel is present") else { return }
        Check.that(cpu.isFinite, "CPU watts is a real number (got \(cpu))")
        Check.that(cpu > 0, "a running Mac is drawing something (got \(cpu) W)")
        // An M4 Max under a synthetic all-core load lands around forty watts.
        // Anything near three figures means a unit was misread.
        Check.that(cpu < 200, "and it is not a misplaced factor of a thousand (got \(cpu) W)")

        if let gpu = power.gpuWatts {
            Check.that(gpu.isFinite && gpu >= 0 && gpu < 200, "GPU watts is plausible (got \(gpu) W)")
        }
        if let ane = power.aneWatts {
            Check.that(ane.isFinite && ane >= 0 && ane < 200, "ANE watts is plausible (got \(ane) W)")
        }
        Check.that((power.totalWatts ?? 0) >= cpu, "the headline number includes the CPU")
        Check.isNil(power.packageWatts,
                    "no package channel is invented out of the parts that do exist")
    }

    Check.suite("energy: every cluster reports how busy it was") {
        let clusters = idle.cpu?.clusters ?? []
        Check.equal(clusters.count, CPUTopology.current.clusters.count, "no cluster went missing")
        for cluster in clusters {
            guard let residency = Check.unwrap(cluster.activeResidency,
                                               "\(cluster.id) has an active residency") else { continue }
            Check.that((0...1).contains(residency),
                       "\(cluster.id) residency is a fraction (got \(residency))")
            if let frequency = cluster.frequencyMHz {
                Check.that((100...6000).contains(frequency),
                           "\(cluster.id) runs at a clock a CPU could have (got \(frequency) MHz)")
            } else {
                Check.equal(residency, 0, "\(cluster.id) only omits a frequency when it never ran")
            }
        }
    }

    Check.suite("energy: the GPU's clock, if the panel asked for one") {
        if let frequency = idle.gpu?.frequencyMHz {
            Check.that((100...4000).contains(frequency),
                       "GPU clock is plausible (got \(frequency) MHz)")
        }
        var withoutGPU = blank()
        withoutGPU.gpu = nil
        probe.read(into: &withoutGPU)
        Check.isNil(withoutGPU.gpu, "a sample with no GPU section does not grow one")
    }

    Check.suite("energy: work costs watts") {
        let baseline = idle.power?.cpuWatts ?? 0
        let loaded = underLoad(for: 1.4) { reading(after: 1.0, from: probe) }

        guard let busy = Check.unwrap(loaded.power?.cpuWatts, "a reading during the load") else { return }
        Check.that(busy > baseline,
                   "saturating every core costs more than not (idle \(baseline) W, loaded \(busy) W)")

        for cluster in loaded.cpu?.clusters ?? [] {
            Check.that((cluster.activeResidency ?? 0) > 0.5,
                       "\(cluster.id) is busy under load (got \(cluster.activeResidency ?? -1))")
            Check.unwrap(cluster.frequencyMHz, "\(cluster.id) reports a frequency while it is running")
        }
    }

    Check.suite("energy: closing gives everything back") {
        probe.close()
        probe.close()

        var afterClose = blank()
        probe.read(into: &afterClose)
        Check.isNil(afterClose.power, "a closed probe reports nothing")

        do {
            try probe.open()
            let again = reading(after: 0.3, from: probe)
            Check.that(again.power?.cpuWatts != nil, "and opens again afterwards")
        } catch {
            Check.that(false, "reopening after close works (\(error))")
        }
        probe.close()
    }

    Check.suite("energy: fifty open/close cycles do not accumulate") {
        // Ten first, so the measurement is not dominated by the one-time cost
        // of warming CoreFoundation's caches and resolving the symbols.
        for _ in 0..<10 {
            try? probe.open()
            probe.close()
        }
        let before = footprintBytes()
        for _ in 0..<50 {
            try? probe.open()
            var sample = blank()
            probe.read(into: &sample)
            probe.close()
        }
        let growth = footprintBytes() - before
        Check.that(growth < 512 * 1024,
                   "the process footprint holds still across fifty cycles (grew \(growth) bytes)")
    }
}
