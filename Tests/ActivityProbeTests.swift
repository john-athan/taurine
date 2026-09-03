import Foundation
import IOKit

/// The probes against the machine they are running on.
///
/// The arithmetic is checked in `ActivityCountersTests`; this file checks the
/// three things no captured input can cover.
///
///   1. That the kernel calls succeed and their numbers are in range and add up.
///   2. That the field a probe reads is the field it claims to read. A swapped
///      pair of struct members is invisible to every test that only asks
///      whether the answer looks plausible, so the answer is held up against the
///      tool macOS ships for the same purpose: `vm_stat` for the page counts,
///      `netstat -ib` for the interface counters.
///   3. That the lifecycle contract in `ActivityProbe` is honoured, which is
///      checked by counting the kernel references this task holds before and
///      after, not by running a loop and declaring it fine.
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

    // MARK: - counting what the task holds

    /// User references on a send right the task holds. The names IOKit and Mach
    /// hand out are per task, and a second lookup of the same object returns the
    /// same name with one more user reference, which is exactly why
    /// `mach_port_names` cannot see these leaks and this can.
    func sendRights(of port: mach_port_t) -> UInt32 {
        var refs: mach_port_urefs_t = 0
        let status = mach_port_get_refs(mach_task_self_, port,
                                        mach_port_right_t(MACH_PORT_RIGHT_SEND), &refs)
        return status == KERN_SUCCESS ? refs : UInt32.max
    }

    /// Send rights on the host port, counted without changing the total:
    /// `mach_host_self` takes one on every call, so this gives it straight back.
    func hostSendRights() -> UInt32 {
        let port = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        return sendRights(of: port)
    }

    /// One accelerator, held for the duration of a test so its port name stays
    /// valid and its reference count stays readable.
    func matchAccelerator() -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let first = IOIteratorNext(iterator)
        var rest = IOIteratorNext(iterator)
        while rest != IO_OBJECT_NULL {
            IOObjectRelease(rest)
            rest = IOIteratorNext(iterator)
        }
        return first == IO_OBJECT_NULL ? nil : first
    }

    /// Everything this process is charged for, its dirty pages and its share of
    /// the compressor alike. The number Xcode's memory gauge shows.
    func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                           / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    // MARK: - the tools macOS ships, used as oracles

    func run(_ path: String, _ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return "" }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }

    /// `vm_stat`'s labelled page counts, keyed by the label it prints.
    func vmStat() -> [String: UInt64] {
        var counts: [String: UInt64] = [:]
        for line in run("/usr/bin/vm_stat", []).split(separator: "\n") {
            let halves = line.split(separator: ":", maxSplits: 1)
            guard halves.count == 2 else { continue }
            let label = halves[0].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            let value = halves[1].trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            if let pages = UInt64(value) { counts[label] = pages }
        }
        return counts
    }

    /// `netstat -ibn`'s per interface byte counters, from its `<Link#n>` rows.
    ///
    /// Parsed from the right hand end: an interface with no hardware address
    /// (`lo0`, `gif0`, `utun0`) leaves the Address column empty, so counting
    /// columns from the left lands one field short on exactly those rows.
    func netstatCounters() -> [String: ByteCounters] {
        var counters: [String: ByteCounters] = [:]
        for line in run("/usr/sbin/netstat", ["-ibn"]).split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 8, fields[2].hasPrefix("<Link#") else { continue }
            // Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
            guard let inbound = UInt64(fields[fields.count - 5]),
                  let outbound = UInt64(fields[fields.count - 2]) else { continue }
            // A down interface is printed with a trailing asterisk.
            let name = String(fields[0].hasSuffix("*") ? fields[0].dropLast() : fields[0])
            counters[name] = ByteCounters(inbound: inbound, outbound: outbound)
        }
        return counters
    }

    // MARK: - processor

    Check.suite("processor probe: this Mac") {
        let probe = ProcessorProbe()
        do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
        defer { probe.close() }

        Thread.sleep(forTimeInterval: gap)
        guard let cpu = Check.unwrap(sample([probe], interval: gap).cpu,
                                     "the first sample already measures against open()'s baseline") else { return }

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

        _ = sample([probe], interval: gap)

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

        guard let m = Check.unwrap(sample([probe], interval: gap).memory, "answers") else { return }

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

    Check.suite("memory probe: every page count is the vm_statistics64 field vm_stat names") {
        let probe = MemoryProbe()
        do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
        defer { probe.close() }

        _ = vmStat()   // warm the spawn path, which itself wires a few hundred pages
        var status: kern_return_t = KERN_SUCCESS
        guard let before = Check.unwrap(probe.pages(status: &status), "host_statistics64 answers") else { return }
        let oracle = vmStat()
        guard let after = Check.unwrap(probe.pages(status: &status), "and answers again") else { return }

        // `vm_stat` is read between two readings of our own, so its number
        // belongs in the window they bracket, plus slack for movement inside the
        // window that we did not see. The slack is per field because these five
        // counts are not equally steady: measured on this Mac over a minute
        // under a parallel build, the compressor pool and the file cache move by
        // single pages while wired and anonymous swing by twenty five thousand
        // (four hundred megabytes) about once a second as other processes come
        // and go. The steady fields are therefore the ones that pin a swapped
        // pair, and they are given the tight slack.
        for (label, ours, theirs, slack) in [
            ("wired", (before.wired, after.wired), oracle["Pages wired down"], UInt64(30_000)),
            ("anonymous", (before.internalPages, after.internalPages), oracle["Anonymous pages"], 30_000),
            ("purgeable", (before.purgeable, after.purgeable), oracle["Pages purgeable"], 15_000),
            ("file backed", (before.external, after.external), oracle["File-backed pages"], 5_000),
            ("compressed", (before.compressed, after.compressed), oracle["Pages occupied by compressor"], 2_000),
        ] {
            guard let theirs = Check.unwrap(theirs, "vm_stat prints a \(label) line") else { continue }
            let low = min(ours.0, ours.1), high = max(ours.0, ours.1)
            Check.that(theirs + slack >= low && theirs <= high + slack,
                       "\(label): vm_stat says \(theirs), the probe read \(low)...\(high) around it")
        }
    }

    // MARK: - storage

    Check.suite("storage probe: this Mac") {
        let probe = StorageProbe()
        do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
        defer { probe.close() }

        Thread.sleep(forTimeInterval: gap)
        guard let a = Check.unwrap(sample([probe], interval: gap).disk,
                                   "the first sample already measures against open()'s baseline") else { return }
        Check.that(a.inboundBytesPerSecond >= 0, "read rate is never negative")
        Check.that(a.outboundBytesPerSecond >= 0, "write rate is never negative")
        Check.that(a.inboundTotal > 0, "the machine has read something since it booted")

        Thread.sleep(forTimeInterval: gap)
        guard let b = Check.unwrap(sample([probe], interval: gap).disk, "a second sample") else { return }
        Check.that(b.inboundTotal >= a.inboundTotal, "the read total only moves forward")
        Check.that(b.outboundTotal >= a.outboundTotal, "and so does the write total")
    }

    Check.suite("storage probe: writing a file moves the write counter") {
        let probe = StorageProbe()
        do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
        defer { probe.close() }

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

        Thread.sleep(forTimeInterval: gap)
        guard let a = Check.unwrap(sample([probe], interval: gap).network,
                                   "the first sample already measures against open()'s baseline") else { return }
        Check.that(a.inboundBytesPerSecond >= 0, "received rate is never negative")
        Check.that(a.outboundBytesPerSecond >= 0, "sent rate is never negative")

        Thread.sleep(forTimeInterval: gap)
        guard let b = Check.unwrap(sample([probe], interval: gap).network, "a second sample") else { return }
        Check.that(b.inboundTotal >= a.inboundTotal, "the received total only moves forward")
        Check.that(b.outboundTotal >= a.outboundTotal, "and so does the sent total")
    }

    Check.suite("network probe: the interface walk excludes what it says it excludes") {
        guard let counters = Check.unwrap(NetworkProbe.interfaceCounters(), "the MIB answers") else { return }
        Check.that(!counters.isEmpty, "at least one interface counts")
        Check.isNil(counters["lo0"], "loopback goes nowhere")
        Check.isNil(counters["gif0"], "nor does a generic tunnel")
        Check.isNil(counters["stf0"], "nor a 6to4 tunnel, which carries no flags to exclude it by")
        Check.isNil(counters["bridge0"], "nor a bridge, whose members are counted individually")
        Check.that(counters.keys.allSatisfy { !$0.hasPrefix("utun") }, "nor any VPN tunnel")
        Check.that(counters["en0"] != nil, "while the interface carrying this Mac's traffic does count")
    }

    Check.suite("network probe: every counted interface agrees with netstat, byte for byte") {
        guard let before = Check.unwrap(NetworkProbe.interfaceCounters(), "a reading before netstat") else { return }
        let oracle = netstatCounters()
        guard let after = Check.unwrap(NetworkProbe.interfaceCounters(), "and one after it") else { return }
        Check.that(!oracle.isEmpty, "netstat printed some link rows")

        // These counters only move forwards, so netstat's reading, taken between
        // two of ours, must sit between them. No tolerance is involved: a probe
        // reading the same 64 bit fields from the same MIB has no excuse for
        // being a byte out, and a probe that has inbound and outbound the wrong
        // way round is off by gigabytes.
        var compared = 0
        var lowTotal = ByteCounters(inbound: 0, outbound: 0)
        var oracleTotal = ByteCounters(inbound: 0, outbound: 0)
        var highTotal = ByteCounters(inbound: 0, outbound: 0)
        for (name, low) in before {
            guard let theirs = oracle[name], let high = after[name] else { continue }
            compared += 1
            Check.that(theirs.inbound >= low.inbound && theirs.inbound <= high.inbound,
                       "\(name) received: netstat says \(theirs.inbound), the probe read "
                       + "\(low.inbound)...\(high.inbound) around it")
            Check.that(theirs.outbound >= low.outbound && theirs.outbound <= high.outbound,
                       "\(name) sent: netstat says \(theirs.outbound), the probe read "
                       + "\(low.outbound)...\(high.outbound) around it")
            lowTotal.inbound += low.inbound;       lowTotal.outbound += low.outbound
            oracleTotal.inbound += theirs.inbound; oracleTotal.outbound += theirs.outbound
            highTotal.inbound += high.inbound;     highTotal.outbound += high.outbound
        }
        Check.that(compared > 0, "at least one interface was in all three readings")
        Check.that(oracleTotal.inbound >= lowTotal.inbound && oracleTotal.inbound <= highTotal.inbound,
                   "and the lifetime received total the panel publishes is netstat's sum")
        Check.that(oracleTotal.outbound >= lowTotal.outbound && oracleTotal.outbound <= highTotal.outbound,
                   "as is the sent total")
    }

    // MARK: - graphics and thermal

    Check.hardwareSuite("graphics probe: this Mac") {
        let probe = GraphicsProbe()
        do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
        defer { probe.close() }

        guard let gpu = Check.unwrap(sample([probe], interval: gap).gpu, "answers") else { return }
        Check.that(gpu.utilization >= 0 && gpu.utilization <= 1, "utilisation is inside 0...1")
        Check.isNil(gpu.frequencyMHz, "frequency is the IOReport probe's, not this one's")
    }

    Check.suite("thermal probe: this Mac") {
        let probe = ThermalProbe()
        do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
        defer { probe.close() }

        guard let thermal = Check.unwrap(sample([probe], interval: gap).thermal, "always answers") else { return }
        Check.that([.nominal, .fair, .serious, .critical].contains(thermal.state),
                   "the state is one the system defines")
    }

    // MARK: - the lifecycle contract

    Check.suite("probes: a closed probe holds no baseline and reports nothing") {
        let probes: [ActivityProbe] = [ProcessorProbe(), StorageProbe(), NetworkProbe()]
        for probe in probes {
            do { try probe.open() } catch { Check.that(false, "\(probe.name) opens: \(error)"); return }
        }
        Thread.sleep(forTimeInterval: gap)
        let warm = sample(probes, interval: gap)
        Check.that(warm.cpu != nil && warm.disk != nil && warm.network != nil,
                   "open() took the baselines, so all three report")

        for probe in probes { probe.close() }
        for probe in probes { probe.close() }   // close is documented as safe twice

        // A rate measured against a baseline from the last time somebody looked
        // would span the hours in between, so closing has to drop it. Reading a
        // closed probe is the sharpest way to ask whether it did.
        let shut = sample(probes, interval: gap)
        Check.isNil(shut.cpu, "processor forgot its baseline")
        Check.isNil(shut.disk, "storage forgot its baseline")
        Check.isNil(shut.network, "network forgot its baseline")

        for probe in probes {
            do { try probe.open() } catch { Check.that(false, "\(probe.name) reopens: \(error)") }
        }
        defer { for probe in probes { probe.close() } }
        Thread.sleep(forTimeInterval: gap)
        let reopened = sample(probes, interval: gap)
        Check.that(reopened.cpu != nil && reopened.disk != nil && reopened.network != nil,
                   "and a reopened probe takes a fresh one")
    }

    Check.suite("processor probe: fifty cycles give back every host port right") {
        let before = hostSendRights()
        for _ in 0..<50 {
            let probe = ProcessorProbe()
            do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
            _ = sample([probe], interval: gap)
            probe.close()
        }
        // mach_host_self hands out a right per call and IOKit hands out a
        // reference per lookup, so a missing deallocate is not a new port name,
        // it is a higher user reference count on a name that was already there.
        Check.equal(hostSendRights(), before,
                    "the task holds no more send rights on the host port than it started with")
    }

    Check.suite("memory probe: fifty cycles give back every host port right") {
        let before = hostSendRights()
        for _ in 0..<50 {
            let probe = MemoryProbe()
            do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
            _ = sample([probe], interval: gap)
            probe.close()
        }
        Check.equal(hostSendRights(), before, "the host port is where it was")
    }

    Check.suite("graphics probe: fifty cycles give back every accelerator reference") {
        guard let watched = matchAccelerator() else {
            Check.that(false, "this Mac has an IOAccelerator to watch")
            return
        }
        defer { IOObjectRelease(watched) }

        let before = sendRights(of: watched)
        for _ in 0..<50 {
            let probe = GraphicsProbe()
            do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
            _ = sample([probe], interval: gap)
            probe.close()
        }
        Check.equal(sendRights(of: watched), before,
                    "the accelerator's user reference count came back to where it started")
    }

    Check.suite("processor probe: a thousand reads give back every array the kernel allocated") {
        let probe = ProcessorProbe()
        do { try probe.open() } catch { Check.that(false, "opens: \(error)"); return }
        defer { probe.close() }

        // host_processor_info allocates its answer in this task's address space
        // and the caller owns it. The allocation is a few hundred bytes and
        // therefore a whole page, so failing to hand it back costs a page per
        // read: sixteen megabytes over this loop, against the megabyte allowed.
        for _ in 0..<200 { _ = sample([probe], interval: gap) }   // warm the allocator
        let before = footprint()
        for _ in 0..<1_000 { _ = sample([probe], interval: gap) }
        let after = footprint()

        let grew = after > before ? after - before : 0
        Check.that(grew < 1_024 * 1_024,
                   "a thousand reads moved this process's footprint by \(grew) bytes")
    }

    Check.suite("probes: a probe dropped without closing still gives everything back") {
        guard let watched = matchAccelerator() else {
            Check.that(false, "this Mac has an IOAccelerator to watch")
            return
        }
        defer { IOObjectRelease(watched) }

        let hostBefore = hostSendRights()
        let acceleratorBefore = sendRights(of: watched)

        /// One cycle that opens three probes and then simply lets go of them.
        /// `ActivityMonitor` never does this, but the protocol puts the release
        /// on the probe, and a released obligation has to survive the holder
        /// forgetting about it.
        func openAndAbandon() -> Bool {
            let processor = ProcessorProbe()
            let memory = MemoryProbe()
            let graphics = GraphicsProbe()
            do {
                try processor.open()
                try memory.open()
                try graphics.open()
            } catch {
                Check.that(false, "opens: \(error)")
                return false
            }
            _ = sample([processor, memory, graphics], interval: gap)
            return true
        }

        for _ in 0..<20 {
            guard openAndAbandon() else { return }
        }

        Check.equal(hostSendRights(), hostBefore,
                    "twenty abandoned processor and memory probes left no host send rights behind")
        Check.equal(sendRights(of: watched), acceleratorBefore,
                    "and twenty abandoned graphics probes left no accelerator references behind")
    }

    // MARK: - through the monitor

    Check.hardwareSuite("monitor: a full panel session start to finish") {
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
