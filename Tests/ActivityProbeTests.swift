import Foundation

/// The probes against the machine they are running on.
///
/// The arithmetic is checked in `ActivityCountersTests`; this file checks the
/// half that no captured input can cover: that the kernel calls succeed, that
/// the numbers they produce are in range and add up, that counters only move
/// forwards, and that the lifecycle contract in `ActivityProbe` is actually
/// honoured. It reads real hardware, so it asserts shapes and bounds rather
/// than values: whether this Mac is 3% busy or 40% busy is not a fact a test
/// gets to have an opinion about.
func runActivityProbeTests() {

    /// Drive a set of probes by hand, the way `ActivityMonitor.tick` does.
    func sample(_ probes: [ActivityProbe], interval: TimeInterval) -> ActivitySample {
        var s = ActivitySample(uptime: ProcessInfo.processInfo.systemUptime, interval: interval)
        for probe in probes { probe.read(into: &s) }
        return s
    }

    /// Long enough for every core to accrue tens of 100 Hz ticks and for the
    /// disk and interface counters to have somewhere to move.
    let gap: TimeInterval = 0.25

    // MARK: - processor

    Check.suite("processor probe: this Mac") {
        let probe = ProcessorProbe()
        do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
        defer { probe.close() }

        let first = sample([probe], interval: 0)
        Check.isNil(first.cpu, "the first sample of a session has no baseline and says so")

        Thread.sleep(forTimeInterval: gap)
        let second = sample([probe], interval: gap)
        guard let cpu = Check.unwrap(second.cpu, "the second sample carries a reading") else { return }

        let topology = CPUTopology.current
        Check.equal(cpu.clusters.map(\.id), topology.clusters.map(\.id), "clusters match the chip")
        Check.equal(cpu.clusters.flatMap(\.cores).count, topology.coreCount, "every core reported once")
        Check.that(cpu.clusters.flatMap(\.cores).allSatisfy { $0 >= 0 && $0 <= 1 },
                   "every core busy fraction is inside 0...1")
        Check.that(cpu.busy >= 0 && cpu.busy <= 1, "and so is the whole-chip figure")
        Check.that(cpu.clusters.allSatisfy { $0.frequencyMHz == nil && $0.activeResidency == nil },
                   "frequency and residency are left for the IOReport probe")
        Check.that(cpu.clusters.contains { $0.kind == .efficiency } || topology.clusters.count == 1,
                   "an Apple Silicon Mac has an efficiency cluster")
    }

    Check.suite("processor probe: a busy loop shows up as busy") {
        let probe = ProcessorProbe()
        do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
        defer { probe.close() }

        _ = sample([probe], interval: 0)

        // One thread spinning for the duration of the interval. The assertion
        // is on the sum of the per-core fractions, not on any single core:
        // macOS migrates a spinning thread between cores several times a
        // second, so a whole busy thread can read as 30% on five different
        // cores and no individual core crosses a half.
        let spinning = Thread {
            let until = Date().addingTimeInterval(0.4)
            var x = 0.0
            while Date() < until { x += 1; if x > 1e12 { x = 0 } }
        }
        spinning.start()
        Thread.sleep(forTimeInterval: 0.4)

        guard let cpu = Check.unwrap(sample([probe], interval: 0.4).cpu, "a reading under load") else { return }
        let coreSeconds = cpu.clusters.flatMap(\.cores).reduce(0, +)
        Check.that(coreSeconds > 0.5, "the chip did at least half a core's worth of work (got \(coreSeconds))")
        Check.that(cpu.busy > 0, "and the chip as a whole was not idle")
    }

    // MARK: - memory

    Check.suite("memory probe: this Mac") {
        let probe = MemoryProbe()
        do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
        defer { probe.close() }

        guard let m = Check.unwrap(sample([probe], interval: 0).memory,
                                   "memory is a level, so it answers on the first sample") else { return }

        Check.equal(m.total, UInt64(CPUTopology.sysctlInt("hw.memsize") ?? 0), "total is hw.memsize")
        Check.equal(m.used, m.app + m.wired + m.compressed, "used is exactly the three buckets")
        Check.that(m.used > 0 && m.used < m.total, "used is a positive figure inside physical memory")
        Check.that(m.wired > 0, "some memory is always wired")
        Check.that(m.app > 0, "and some belongs to processes")
        Check.that(m.cached > 0, "a running Mac always has file cache")
        Check.that(m.used + m.cached <= m.total, "used and cache together still fit in the machine")
        Check.that(m.usedFraction > 0 && m.usedFraction <= 1, "the fraction is a fraction")
        Check.that(m.swapUsed <= m.swapTotal || m.swapTotal == 0, "swap used fits in the swap file")
    }

    // MARK: - storage

    Check.suite("storage probe: this Mac") {
        let probe = StorageProbe()
        do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
        defer { probe.close() }

        Check.isNil(sample([probe], interval: 0).disk, "cumulative counters carry no rate on the first sample")

        Thread.sleep(forTimeInterval: gap)
        guard let a = Check.unwrap(sample([probe], interval: gap).disk, "a rate on the second sample") else { return }
        Check.that(a.inboundBytesPerSecond >= 0, "read rate is never negative")
        Check.that(a.outboundBytesPerSecond >= 0, "write rate is never negative")
        Check.that(a.inboundTotal > 0, "the machine has read something since it booted")

        Thread.sleep(forTimeInterval: gap)
        guard let b = Check.unwrap(sample([probe], interval: gap).disk, "a third sample") else { return }
        Check.that(b.inboundTotal >= a.inboundTotal, "the read total only moves forward")
        Check.that(b.outboundTotal >= a.outboundTotal, "and so does the write total")
    }

    Check.suite("storage probe: writing a file moves the write counter") {
        let probe = StorageProbe()
        do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
        defer { probe.close() }

        _ = sample([probe], interval: 0)

        // Eight megabytes, synced, so the bytes are on their way to the device
        // rather than sitting in the unified buffer cache.
        let path = NSTemporaryDirectory() + "taurine-storage-probe-\(getpid()).bin"
        let payload = Data(repeating: 0x5A, count: 8 * 1024 * 1024)
        var wrote = false
        if let handle = FileHandle(forWritingAtPath: path) ?? {
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)
        }() {
            try? handle.write(contentsOf: payload)
            _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
            try? handle.close()
            wrote = true
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        guard wrote else { Check.that(false, "the temporary file could be written"); return }
        guard let disk = Check.unwrap(sample([probe], interval: 1).disk, "a reading after the write") else { return }
        Check.that(disk.outboundBytesPerSecond > 0, "eight megabytes and a full fsync reached the device")
    }

    // MARK: - network

    Check.suite("network probe: this Mac") {
        let probe = NetworkProbe()
        do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
        defer { probe.close() }

        Check.isNil(sample([probe], interval: 0).network, "no rate without a baseline")

        Thread.sleep(forTimeInterval: gap)
        guard let a = Check.unwrap(sample([probe], interval: gap).network, "a rate on the second sample") else { return }
        Check.that(a.inboundBytesPerSecond >= 0, "received rate is never negative")
        Check.that(a.outboundBytesPerSecond >= 0, "sent rate is never negative")

        Thread.sleep(forTimeInterval: gap)
        guard let b = Check.unwrap(sample([probe], interval: gap).network, "a third sample") else { return }
        Check.that(b.inboundTotal >= a.inboundTotal, "the received total only moves forward")
        Check.that(b.outboundTotal >= a.outboundTotal, "and so does the sent total")
    }

    Check.suite("network probe: the interface walk agrees with the kernel") {
        guard let counters = Check.unwrap(NetworkProbe.interfaceCounters(), "getifaddrs answers") else { return }
        Check.that(!counters.isEmpty, "at least one interface counts")
        Check.that(counters["lo0"] == nil, "loopback is not among them")
        Check.that(counters.keys.allSatisfy { !$0.hasPrefix("utun") }, "nor is any VPN tunnel")
        Check.that(counters.keys.allSatisfy { !$0.hasPrefix("bridge") }, "nor any bridge")
        Check.that(counters.values.allSatisfy { $0.inbound < 1 << 32 && $0.outbound < 1 << 32 },
                   "every reading fits in the 32 bit counter it came from")
    }

    // MARK: - graphics and thermal

    Check.suite("graphics probe: this Mac") {
        let probe = GraphicsProbe()
        do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
        defer { probe.close() }

        guard let gpu = Check.unwrap(sample([probe], interval: 0).gpu,
                                     "utilisation is a level, so it answers on the first sample") else { return }
        Check.that(gpu.utilization >= 0 && gpu.utilization <= 1, "utilisation is inside 0...1")
        Check.isNil(gpu.frequencyMHz, "frequency is Phase 2's, not this probe's")
    }

    Check.suite("thermal probe: this Mac") {
        let probe = ThermalProbe()
        do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
        defer { probe.close() }

        guard let thermal = Check.unwrap(sample([probe], interval: 0).thermal, "always answers") else { return }
        Check.that([.nominal, .fair, .serious, .critical].contains(thermal.state),
                   "the state is one the system defines")
    }

    // MARK: - the lifecycle contract

    Check.suite("probes: closing forgets the baseline") {
        let probes: [ActivityProbe] = [ProcessorProbe(), StorageProbe(), NetworkProbe()]
        for probe in probes {
            do { try probe.open() } catch { Check.that(false, "\(probe.name) opens: \(error)"); continue }
        }
        _ = sample(probes, interval: 0)
        Thread.sleep(forTimeInterval: gap)
        let warm = sample(probes, interval: gap)
        Check.that(warm.cpu != nil && warm.disk != nil && warm.network != nil, "warmed up, all three report")

        for probe in probes { probe.close() }
        for probe in probes {
            do { try probe.open() } catch { Check.that(false, "\(probe.name) reopens: \(error)") }
        }
        defer { for probe in probes { probe.close() } }

        // The first sample after reopening must be blank again. If a probe kept
        // its baseline across close(), this reading would be a rate measured
        // over the gap between two panel sessions, which could be hours.
        let reopened = sample(probes, interval: gap)
        Check.isNil(reopened.cpu, "processor took a fresh baseline")
        Check.isNil(reopened.disk, "storage took a fresh baseline")
        Check.isNil(reopened.network, "network took a fresh baseline")
    }

    Check.suite("probes: fifty open and close cycles hold nothing") {
        // Every probe here owns something the kernel counts: a mach port, a set
        // of io_service_t references. A missing deallocate shows up as this loop
        // eventually failing to open, long before it shows up as a memory
        // figure somebody notices.
        for _ in 0..<50 {
            let probes: [ActivityProbe] = [ProcessorProbe(), MemoryProbe(), StorageProbe(),
                                           NetworkProbe(), GraphicsProbe(), ThermalProbe()]
            for probe in probes {
                do { try probe.open() } catch { Check.that(false, "\(probe.name) opens: \(error)") }
            }
            _ = sample(probes, interval: 0)
            for probe in probes { probe.close() }
            for probe in probes { probe.close() }   // close is documented as safe twice
        }
        let survivor = ProcessorProbe()
        do { try survivor.open() } catch { Check.that(false, "still openable afterwards: \(error)") }
        survivor.close()
        Check.that(true, "fifty cycles later the kernel still hands out ports and services")
    }

    // MARK: - through the monitor

    Check.suite("monitor: a full panel session start to finish") {
        let monitor = ActivityMonitor(probes: [ProcessorProbe(), MemoryProbe(), StorageProbe(),
                                               NetworkProbe(), GraphicsProbe(), ThermalProbe()])
        var samples: [ActivitySample] = []
        monitor.onSample = { samples.append($0) }
        monitor.start(interval: 0.2)
        Check.that(monitor.isRunning, "the one timer exists while the panel is open")

        let deadline = Date().addingTimeInterval(3)
        while samples.count < 3 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        monitor.stop()
        Check.that(!monitor.isRunning, "and is gone the moment it closes")

        let missing = samples.first?.unavailable ?? []
        Check.that(missing.isEmpty,
                   "every public-API probe opened on this Mac (\(missing.map(\.name)))")
        guard samples.count >= 3 else {
            Check.that(false, "three samples arrived (got \(samples.count))")
            return
        }
        Check.that(samples[0].interval > 0, "the first sample measures a real span of time")
        Check.that(samples[1].interval > 0, "and so does every one after it")
        Check.that(samples[0].memory != nil && samples[0].gpu != nil && samples[0].thermal != nil,
                   "levels are present from the very first frame")
        Check.that(samples[0].cpu != nil && samples[0].disk != nil && samples[0].network != nil,
                   "and so are the rates, because the probes took their baseline when they opened")
    }
}
