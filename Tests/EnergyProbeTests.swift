import Foundation

/// The probe against the machine it is running on. 🔌
///
/// The arithmetic is tested elsewhere, without hardware. What is left is
/// everything that only reality can answer: whether the private framework still
/// exists, whether the numbers that come out of it are the right order of
/// magnitude, whether they move when the machine works, and whether closing the
/// panel really does give everything back.
///
/// The readings are deliberately loose. Asserting a specific wattage would fail
/// on every Mac but the one it was written on; asserting that a saturated chip
/// draws more than an idle one is true of all of them.
///
/// The three suites that count what the probe holds are the opposite: they
/// assert an exact number, because they count mach port names and a live
/// subscription is worth exactly one. A leak test that has to pick a threshold
/// is a leak test that will one day pick wrong.
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

    /// A reading over a window of about `seconds`, and not a moment longer.
    ///
    /// The discarded read is what makes that true: the probe measures from its
    /// own last reading, so without one the window would stretch back to
    /// whatever the suite before this one happened to be doing.
    func reading(after seconds: TimeInterval, from probe: EnergyProbe) -> ActivitySample {
        var discarded = blank()
        probe.read(into: &discarded)
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

    /// Every mach port name this task holds, as a set.
    ///
    /// This is the instrument the three leak suites below pull on, because a
    /// live IOReport subscription costs the task exactly one port name and
    /// giving the subscription back gives the name back. Twenty abandoned
    /// subscriptions are twenty names that were not there before, which is a
    /// fact rather than a distribution.
    ///
    /// The set, and not the count, because the count drifts: the threads other
    /// suites start carry port names of their own and hand them back when the
    /// kernel reaps them, which happened four names' worth in the middle of
    /// this file's first run. Names that *appeared* and stayed are what a leak
    /// looks like, and reaping cannot add any.
    ///
    /// `phys_footprint` cannot do this job at this resolution, which is why it
    /// is not used here. Each `open()` pushes a ten-thousand entry dictionary
    /// through malloc and the zones behind it grow in quarter-megabyte steps
    /// early in a process's life: measured over fifty cycles it moved by
    /// anywhere from nothing to 950 KB in a fresh process while `leaks
    /// --atExit` was reporting none, which is a coin toss wearing a threshold.
    func machPortNames() -> Set<mach_port_name_t> {
        var names: mach_port_name_array_t?
        var nameCount: mach_msg_type_number_t = 0
        var types: mach_port_type_array_t?
        var typeCount: mach_msg_type_number_t = 0
        guard mach_port_names(mach_task_self_, &names, &nameCount, &types, &typeCount) == KERN_SUCCESS,
              let names else {
            return []
        }
        let held = Set(UnsafeBufferPointer(start: names, count: Int(nameCount)))
        // Both arrays come back in freshly allocated VM. Counting them and then
        // leaking them would be a fine joke at this test's expense.
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: names)),
                      vm_size_t(Int(nameCount) * MemoryLayout<mach_port_name_t>.size))
        if let types {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: types)),
                          vm_size_t(Int(typeCount) * MemoryLayout<mach_port_type_t>.size))
        }
        return held
    }

    let probe = EnergyProbe()
    var opened = false

    Check.hardwareSuite("energy: the private framework is still there") {
        do {
            try probe.open()
            opened = true
        } catch {
            Check.that(false, "the probe opens on an Apple Silicon Mac (\(error))")
        }
    }

    Check.suite("energy: a window too short to divide by yields nothing") {
        // The baseline was taken microseconds ago, at the end of open().
        // Millijoule counters over a window that short are quantisation, not a
        // reading. The window is measured rather than assumed, so that a
        // machine that stalled for a twentieth of a second between the two
        // makes this check vacuous instead of making it fail: the claim is
        // about short windows, and that is exactly what it says.
        let openedAt = ProcessInfo.processInfo.systemUptime
        var immediate = blank()
        probe.read(into: &immediate)
        let window = ProcessInfo.processInfo.systemUptime - openedAt
        Check.that(window >= 0.05 || immediate.power == nil,
                   "no power tile on the first frame of a session (window \(window) s)")
    }

    // Ahead of the guard below, because this is the one thing here that has
    // something to say on a Mac where opening fails. It runs its own probes.
    Check.suite("energy: an open that throws leaves nothing behind") {
        // ActivityMonitor drops a probe whose open() threw without ever calling
        // close() on it, so on that path the throw itself has to give back
        // whatever it had already taken. The probes are kept alive here for
        // exactly that reason: letting them deinit would cover the mistake up.
        var abandoned: [EnergyProbe] = []
        let before = machPortNames()
        for _ in 0..<8 {
            let probe = EnergyProbe()
            abandoned.append(probe)
            do { try probe.open() } catch { continue }
            probe.close()
        }

        // The one failure the bridge can be made to produce to order. It throws
        // part way through building the filtered legend, which is the path that
        // has to leave the count below where it found it.
        Check.throwsError("a subscription to a group IOReport does not publish is refused, not left empty") {
            _ = try IOReportBridge(subscribingTo: [.init("no group of this name is published")])
        }

        let survivors = machPortNames().subtracting(before)
        Check.equal(survivors.count, 0,
                    "\(abandoned.count) probes opened the way the monitor opens them hold no subscription "
                        + "(\(survivors.count) port names outlived them)")
    }

    guard opened else { return }
    defer { probe.close() }

    let idle = reading(after: 0.4, from: probe)

    Check.suite("energy: an unloaded chip draws a plausible number of watts") {
        guard let power = Check.unwrap(idle.power, "the power section is filled in") else { return }
        guard let cpu = Check.unwrap(power.cpuWatts, "the CPU energy channel is present") else { return }
        Check.that(cpu.isFinite, "CPU watts is a real number (got \(cpu))")
        Check.that(cpu > 0, "a running Mac is drawing something (got \(cpu) W)")
        // This M4 Pro reads about 29 W on its CPU energy channel with every
        // core saturated, so an idle one has a great deal of room below the
        // ceiling. What the ceiling catches is a unit misread by a factor of a
        // thousand, which would land the reading in the tens of thousands.
        Check.that(cpu < 200, "and it is not a misplaced factor of a thousand (got \(cpu) W)")

        Check.that(power.gpuWatts.map { $0.isFinite && $0 >= 0 && $0 < 200 } ?? true,
                   "GPU watts, when the chip publishes them, is plausible (got \(String(describing: power.gpuWatts)))")
        Check.that(power.aneWatts.map { $0.isFinite && $0 >= 0 && $0 < 200 } ?? true,
                   "so is the Neural Engine's (got \(String(describing: power.aneWatts)))")
    }

    Check.suite("energy: every cluster reports how busy it was") {
        let clusters = idle.cpu?.clusters ?? []
        Check.equal(clusters.count, CPUTopology.current.clusters.count, "no cluster went missing")
        for cluster in clusters {
            guard let residency = Check.unwrap(cluster.activeResidency,
                                               "\(cluster.id) has an active residency") else { continue }
            Check.that((0...1).contains(residency),
                       "\(cluster.id) residency is a fraction (got \(residency))")
            // A cluster reports no frequency when it never left idle, and also
            // when its states lined up against no table we could read. Both are
            // honest silences, and neither is worth failing over; a number
            // outside the range a CPU can clock at is not.
            Check.that(cluster.frequencyMHz.map { (100...6000).contains($0) } ?? true,
                       "\(cluster.id) runs at a clock a CPU could have (got \(String(describing: cluster.frequencyMHz)))")
        }
    }

    Check.suite("energy: the GPU's clock, if the panel asked for one") {
        Check.that(idle.gpu?.frequencyMHz.map { (100...4000).contains($0) } ?? true,
                   "GPU clock is plausible (got \(String(describing: idle.gpu?.frequencyMHz)))")
        var withoutGPU = blank()
        withoutGPU.gpu = nil
        probe.read(into: &withoutGPU)
        Check.isNil(withoutGPU.gpu, "a sample with no GPU section does not grow one")
    }

    // These two run before the load suite below, which detaches a thread per
    // core: those threads carry port names of their own and hand them back when
    // the kernel reaps them, and an instrument this exact should not have to
    // argue with them.

    Check.suite("energy: twenty open/read/close cycles give every subscription back") {
        // Its own probe, so the shared one keeps its baseline. Five cycles
        // first: the first open resolves the symbols and warms CoreFoundation's
        // caches, and a port name taken once and kept is not a leak.
        let cycler = EnergyProbe()
        for _ in 0..<5 {
            try? cycler.open()
            cycler.close()
        }
        let before = machPortNames()
        for _ in 0..<20 {
            try? cycler.open()
            var sample = blank()
            cycler.read(into: &sample)
            cycler.close()
        }
        let survivors = machPortNames().subtracting(before)
        Check.equal(survivors.count, 0,
                    "no mach port name outlived the cycles (\(survivors.count) did)")
    }

    Check.suite("energy: a probe dropped without closing still gives everything back") {
        let before = machPortNames()
        for _ in 0..<12 {
            let dropped = EnergyProbe()
            try? dropped.open()
            // No close(). What gives the subscription back here is ARC letting
            // go of the bridge and the bridge's own deinit releasing it, and
            // this is the test that says so.
        }
        let survivors = machPortNames().subtracting(before)
        Check.equal(survivors.count, 0,
                    "twelve abandoned probes left no subscription behind (\(survivors.count) port names did)")
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
}
