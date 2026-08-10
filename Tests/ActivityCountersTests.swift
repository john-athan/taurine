import Foundation

/// The arithmetic behind the activity panel, with the kernel taken out.
///
/// Everything here is a pure function over numbers that were captured from a
/// real machine or invented to be awkward. The awkward ones are the point: a
/// counter that wraps, a disk that vanishes, a first sample with no baseline,
/// an interval of zero. Those happen once a week on somebody's Mac and never
/// while you are watching, so this is the only place they can be checked.
func runActivityCountersTests() {

    // MARK: - RateCounter

    Check.suite("rate counter: the first reading is a baseline, not a measurement") {
        var c = RateCounter()
        Check.that(!c.hasBaseline, "starts with nothing to compare against")
        Check.isNil(c.advance(to: 1000), "first reading yields no delta")
        Check.that(c.hasBaseline, "and leaves a baseline behind")
        Check.equal(c.advance(to: 1500), 500, "second reading measures the gap")
    }

    Check.suite("rate counter: deltas accumulate across readings") {
        var c = RateCounter()
        _ = c.advance(to: 10)
        Check.equal(c.advance(to: 20), 10, "first gap")
        Check.equal(c.advance(to: 20), 0, "a counter that did not move measures zero, which is a real answer")
        Check.equal(c.advance(to: 100), 80, "second gap")
    }

    Check.suite("rate counter: a counter of unknown width that goes backwards yields nothing") {
        var c = RateCounter()
        _ = c.advance(to: 4_294_967_000)
        Check.isNil(c.advance(to: 12_000), "a reset is not a negative rate and not a spike either")
        Check.equal(c.advance(to: 30_000), 18_000, "and the tick after it measures normally again")
    }

    Check.suite("rate counter: a 32 bit counter that wraps is reconstructed exactly") {
        var c = RateCounter(modulus: 1 << 32)
        _ = c.advance(to: 4_294_967_200)          // 96 short of 2^32
        Check.equal(c.advance(to: 400), 496, "96 to the roll-over plus 400 after it")
        Check.equal(c.advance(to: 1_400), 1_000, "and the counter carries on normally")
    }

    Check.suite("rate counter: a wrap reconstruction never exceeds the modulus") {
        var c = RateCounter(modulus: 1 << 32)
        _ = c.advance(to: 10)
        let delta = Check.unwrap(c.advance(to: 5), "an almost-full wrap")
        Check.that((delta ?? 0) < 1 << 32, "the worst case is one whole turn of the counter, never more")
        Check.equal(delta, (1 << 32) - 10 + 5, "and it is the exact arithmetic, not a guess")
    }

    Check.suite("rate counter: a reading beyond the stated modulus is refused") {
        var c = RateCounter(modulus: 1 << 32)
        _ = c.advance(to: 1 << 40)
        Check.isNil(c.advance(to: 5), "a counter wider than we were told is a reset, not a wrap")
    }

    Check.suite("rate counter: forgetting drops the baseline") {
        var c = RateCounter()
        _ = c.advance(to: 500)
        c.forget()
        Check.that(!c.hasBaseline, "no baseline survives a close")
        Check.isNil(c.advance(to: 900), "so the next reading is a baseline again, not a 900 byte spike")
    }

    // MARK: - TrafficLedger

    Check.suite("ledger: the first tick has no rate to report") {
        var ledger = TrafficLedger<String>()
        let first = ledger.update(["en0": ByteCounters(inbound: 1_000, outbound: 500)], over: 0)
        Check.isNil(first, "interval zero and no baseline means no traffic rate at all")
    }

    Check.suite("ledger: rates are bytes per second over the interval") {
        var ledger = TrafficLedger<String>()
        _ = ledger.update(["en0": ByteCounters(inbound: 1_000, outbound: 500)], over: 0)
        let r = Check.unwrap(ledger.update(["en0": ByteCounters(inbound: 3_000, outbound: 1_500)], over: 2),
                             "a second reading two seconds later")
        Check.close(r?.inboundBytesPerSecond ?? -1, 1_000, tolerance: 0.001, "2000 bytes over 2 seconds")
        Check.close(r?.outboundBytesPerSecond ?? -1, 500, tolerance: 0.001, "1000 bytes over 2 seconds")
    }

    Check.suite("ledger: totals start at the counters and then track deltas") {
        var ledger = TrafficLedger<String>()
        _ = ledger.update(["en0": ByteCounters(inbound: 800, outbound: 100),
                           "en1": ByteCounters(inbound: 200, outbound: 50)], over: 0)
        let r = Check.unwrap(ledger.update(["en0": ByteCounters(inbound: 900, outbound: 100),
                                            "en1": ByteCounters(inbound: 200, outbound: 90)], over: 1),
                             "a second reading")
        Check.equal(r?.inboundTotal, 1_100, "seeded at 1000, advanced by 100")
        Check.equal(r?.outboundTotal, 190, "seeded at 150, advanced by 40")
    }

    Check.suite("ledger: a source that vanishes stops contributing and takes nothing with it") {
        var ledger = TrafficLedger<String>()
        _ = ledger.update(["disk0": ByteCounters(inbound: 1_000, outbound: 0),
                           "disk1": ByteCounters(inbound: 5_000, outbound: 0)], over: 0)
        let r = Check.unwrap(ledger.update(["disk0": ByteCounters(inbound: 1_400, outbound: 0)], over: 1),
                             "disk1 was unplugged between ticks")
        Check.close(r?.inboundBytesPerSecond ?? -1, 400, tolerance: 0.001,
                    "the rate is what the surviving disk did, not a 5 KB cliff")
        Check.equal(r?.inboundTotal, 6_400, "and the total keeps the bytes disk1 already moved")
    }

    Check.suite("ledger: a source that appears contributes nothing on its first tick") {
        var ledger = TrafficLedger<String>()
        _ = ledger.update(["disk0": ByteCounters(inbound: 1_000, outbound: 0)], over: 0)
        let r = Check.unwrap(ledger.update(["disk0": ByteCounters(inbound: 1_100, outbound: 0),
                                            "disk1": ByteCounters(inbound: 9_000_000, outbound: 0)], over: 1),
                             "a USB disk with a lifetime counter was plugged in")
        Check.close(r?.inboundBytesPerSecond ?? -1, 100, tolerance: 0.001,
                    "its lifetime counter is a baseline, not nine megabytes in one second")
        Check.equal(r?.inboundTotal, 1_100, "and it does not inflate the total either")
    }

    Check.suite("ledger: a wrapped source blanks the tick rather than under-reporting it") {
        var ledger = TrafficLedger<String>()
        _ = ledger.update(["en0": ByteCounters(inbound: 4_294_000_000, outbound: 10)], over: 0)
        Check.isNil(ledger.update(["en0": ByteCounters(inbound: 4_000, outbound: 20)], over: 1),
                    "we cannot tell a wrap from a reset, so we say nothing for one tick")
        let r = Check.unwrap(ledger.update(["en0": ByteCounters(inbound: 9_000, outbound: 30)], over: 1),
                             "the tick after recovers")
        Check.close(r?.inboundBytesPerSecond ?? -1, 5_000, tolerance: 0.001, "measured from the post-wrap baseline")
    }

    Check.suite("ledger: a ledger told its counter width rides the wrap instead of blanking") {
        var ledger = TrafficLedger<String>(modulus: 1 << 32)
        _ = ledger.update(["en0": ByteCounters(inbound: 4_294_967_000, outbound: 0)], over: 0)
        let r = Check.unwrap(ledger.update(["en0": ByteCounters(inbound: 296, outbound: 0)], over: 1),
                             "the interface rolled over mid-download")
        Check.close(r?.inboundBytesPerSecond ?? -1, 592, tolerance: 0.001,
                    "296 bytes to the roll-over plus 296 after it")
        Check.equal(r?.inboundTotal, 4_294_967_592, "and the running total steps over the boundary")
    }

    Check.suite("ledger: an interval of zero never divides") {
        var ledger = TrafficLedger<String>()
        _ = ledger.update(["en0": ByteCounters(inbound: 100, outbound: 100)], over: 0)
        Check.isNil(ledger.update(["en0": ByteCounters(inbound: 200, outbound: 200)], over: 0),
                    "a zero interval carries no rate, however good the baseline is")
    }

    Check.suite("ledger: forgetting drops every baseline") {
        var ledger = TrafficLedger<String>()
        _ = ledger.update(["en0": ByteCounters(inbound: 100, outbound: 100)], over: 0)
        ledger.forget()
        Check.isNil(ledger.update(["en0": ByteCounters(inbound: 100, outbound: 100)], over: 1),
                    "a reopened ledger takes a fresh baseline")
    }

    // MARK: - processor ticks

    Check.suite("processor: busy is everything that is not idle") {
        // One core: 30 user ticks, 10 system, 60 idle, 0 nice.
        let a = [ProcessorProbe.CoreTicks(user: 100, system: 100, idle: 100, nice: 0)]
        let b = [ProcessorProbe.CoreTicks(user: 130, system: 110, idle: 160, nice: 0)]
        let busy = Check.unwrap(ProcessorProbe.busy(from: a, to: b), "two readings give a fraction")
        Check.close(busy?.first ?? -1, 0.4, tolerance: 0.0001, "40 busy ticks out of 100")
    }

    Check.suite("processor: nice counts as busy") {
        let a = [ProcessorProbe.CoreTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let b = [ProcessorProbe.CoreTicks(user: 0, system: 0, idle: 50, nice: 50)]
        let busy = Check.unwrap(ProcessorProbe.busy(from: a, to: b), "a core running only nice work")
        Check.close(busy?.first ?? -1, 0.5, tolerance: 0.0001, "nice is work, not idleness")
    }

    Check.suite("processor: a saturated core and an idle core read 1 and 0") {
        let a = [ProcessorProbe.CoreTicks(user: 0, system: 0, idle: 0, nice: 0),
                 ProcessorProbe.CoreTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let b = [ProcessorProbe.CoreTicks(user: 100, system: 0, idle: 0, nice: 0),
                 ProcessorProbe.CoreTicks(user: 0, system: 0, idle: 100, nice: 0)]
        let busy = Check.unwrap(ProcessorProbe.busy(from: a, to: b), "two cores")
        Check.close(busy?[0] ?? -1, 1.0, tolerance: 0.0001, "saturated")
        Check.close(busy?[1] ?? -1, 0.0, tolerance: 0.0001, "idle")
    }

    Check.suite("processor: a tick counter that wrapped yields no reading at all") {
        let a = [ProcessorProbe.CoreTicks(user: 4_294_967_200, system: 0, idle: 0, nice: 0)]
        let b = [ProcessorProbe.CoreTicks(user: 50, system: 0, idle: 100, nice: 0)]
        Check.isNil(ProcessorProbe.busy(from: a, to: b), "one wrapped core blanks the whole reading")
    }

    Check.suite("processor: no time passing yields no reading") {
        let a = [ProcessorProbe.CoreTicks(user: 10, system: 10, idle: 10, nice: 10)]
        Check.isNil(ProcessorProbe.busy(from: a, to: a), "zero ticks elapsed is a division we refuse to do")
    }

    Check.suite("processor: readings of different shapes are not compared") {
        let a = [ProcessorProbe.CoreTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let b = [ProcessorProbe.CoreTicks(user: 1, system: 0, idle: 1, nice: 0),
                 ProcessorProbe.CoreTicks(user: 1, system: 0, idle: 1, nice: 0)]
        Check.isNil(ProcessorProbe.busy(from: a, to: b), "a core count that changed invalidates the baseline")
        Check.isNil(ProcessorProbe.busy(from: [], to: []), "and an empty machine reports nothing")
    }

    Check.suite("processor: the raw tick array decodes in kernel order") {
        // host_processor_info hands back user, system, idle, nice per core, flat.
        let raw: [natural_t] = [1, 2, 3, 4, 10, 20, 30, 40]
        let cores = ProcessorProbe.decode(raw, cores: 2)
        Check.equal(cores.count, 2, "two cores out of eight numbers")
        Check.equal(cores[0], ProcessorProbe.CoreTicks(user: 1, system: 2, idle: 3, nice: 4), "first core")
        Check.equal(cores[1], ProcessorProbe.CoreTicks(user: 10, system: 20, idle: 30, nice: 40), "second core")
        Check.equal(ProcessorProbe.decode(raw, cores: 3).count, 2, "a short array is truncated, never read past")
    }

    // MARK: - clustering

    Check.suite("processor: cores are dealt into the chip's clusters") {
        let topology = CPUTopology.compose(levels: [
            .init(name: "Performance", logicalCPUs: 4, coresPerL2: 2),
            .init(name: "Efficiency", logicalCPUs: 2, coresPerL2: 2),
        ])
        let cores = [0.1, 0.2, 0.5, 0.6, 0.7, 0.8]
        let clusters = Check.unwrap(ProcessorProbe.clusters(from: cores, topology: topology), "six cores, three clusters")
        Check.equal(clusters?.map(\.id), ["E", "P0", "P1"], "cluster identities come from the topology")
        Check.equal(clusters?[0].cores, [0.1, 0.2], "efficiency cluster takes the low core numbers")
        Check.equal(clusters?[2].cores, [0.7, 0.8], "last performance cluster takes the high ones")
        Check.equal(clusters?[0].kind, .efficiency, "and keeps its kind")
        Check.close(clusters?[1].busy ?? -1, 0.55, tolerance: 0.0001, "cluster busy is the mean of its cores")
        Check.isNil(clusters?[0].frequencyMHz, "frequency is not this probe's to answer")
    }

    Check.suite("processor: a core count that disagrees with the topology is refused") {
        let topology = CPUTopology.compose(levels: [.init(name: "Performance", logicalCPUs: 4, coresPerL2: 4)])
        Check.isNil(ProcessorProbe.clusters(from: [0.1, 0.2], topology: topology),
                    "two readings cannot be spread over four cores without inventing two")
    }

    Check.suite("processor: the whole-chip figure is weighted by core count") {
        let topology = CPUTopology.compose(levels: [
            .init(name: "Performance", logicalCPUs: 10, coresPerL2: 10),
            .init(name: "Efficiency", logicalCPUs: 4, coresPerL2: 4),
        ])
        let cores = Array(repeating: 1.0, count: 4) + Array(repeating: 0.0, count: 10)
        let clusters = Check.unwrap(ProcessorProbe.clusters(from: cores, topology: topology), "four saturated E cores")
        let activity = CPUActivity(clusters: clusters ?? [])
        Check.close(activity.busy, 4.0 / 14.0, tolerance: 0.0001, "29%, not 50%")
    }

    // MARK: - memory accounting

    Check.suite("memory: used is app plus wired plus compressed") {
        // Page counts captured from this Mac, 16 KB pages.
        let pages = MemoryProbe.PageCounts(wired: 149_000, internalPages: 673_000,
                                           external: 286_000, purgeable: 6_000, compressed: 405_000)
        let m = MemoryProbe.account(pages, pageSize: 16_384, physical: 25_769_803_776,
                                    swapUsed: 2_308_833_280, swapTotal: 3_221_225_472)
        Check.equal(m.app, (673_000 - 6_000) * 16_384, "app memory is anonymous pages minus the purgeable ones")
        Check.equal(m.wired, 149_000 * 16_384, "wired is wired")
        Check.equal(m.compressed, 405_000 * 16_384, "compressed is what the compressor holds")
        Check.equal(m.cached, (286_000 + 6_000) * 16_384, "cached files are file backed plus purgeable")
        Check.equal(m.used, m.app + m.wired + m.compressed, "and used is exactly those three")
        Check.that(m.used < m.total, "used fits inside physical memory")
        Check.close(m.usedFraction, Double(m.used) / Double(m.total), tolerance: 0.0001, "fraction agrees")
    }

    Check.suite("memory: cached memory is deliberately outside used") {
        let pages = MemoryProbe.PageCounts(wired: 10, internalPages: 10,
                                           external: 1_000_000, purgeable: 0, compressed: 10)
        let m = MemoryProbe.account(pages, pageSize: 16_384, physical: 25_769_803_776,
                                    swapUsed: 0, swapTotal: 0)
        Check.equal(m.used, 30 * 16_384, "a terabyte of cache does not make the machine look full")
    }

    Check.suite("memory: more purgeable pages than anonymous ones does not underflow") {
        // The two counters are sampled at slightly different moments inside the
        // kernel, so purgeable can briefly exceed internal. On UInt64 that
        // subtraction would wrap to sixteen exabytes of app memory.
        let pages = MemoryProbe.PageCounts(wired: 100, internalPages: 5,
                                           external: 10, purgeable: 9, compressed: 1)
        let m = MemoryProbe.account(pages, pageSize: 16_384, physical: 25_769_803_776,
                                    swapUsed: 0, swapTotal: 0)
        Check.equal(m.app, 0, "app memory floors at zero instead of wrapping")
        Check.that(m.used < m.total, "and used stays sane")
    }

    Check.suite("memory: a machine with swap turned off reports zero, not nonsense") {
        let pages = MemoryProbe.PageCounts(wired: 100, internalPages: 100,
                                           external: 100, purgeable: 0, compressed: 0)
        let m = MemoryProbe.account(pages, pageSize: 16_384, physical: 8_589_934_592,
                                    swapUsed: 0, swapTotal: 0)
        Check.equal(m.swapUsed, 0, "no swap used")
        Check.equal(m.swapTotal, 0, "no swap file")
        Check.equal(m.total, 8_589_934_592, "physical memory comes from the machine, not from the page sums")
    }

    // MARK: - graphics

    Check.suite("graphics: utilisation is a percentage turned into a fraction") {
        Check.close(GraphicsProbe.utilization(fromPercent: 0), 0, tolerance: 0.0001, "idle")
        Check.close(GraphicsProbe.utilization(fromPercent: 42), 0.42, tolerance: 0.0001, "mid load")
        Check.close(GraphicsProbe.utilization(fromPercent: 100), 1, tolerance: 0.0001, "saturated")
    }

    Check.suite("graphics: a percentage outside 0...100 is clamped, not passed on") {
        Check.close(GraphicsProbe.utilization(fromPercent: 140), 1, tolerance: 0.0001,
                    "the driver occasionally overshoots across a sampling boundary")
        Check.close(GraphicsProbe.utilization(fromPercent: -3), 0, tolerance: 0.0001, "and undershoots")
    }

    // MARK: - which interfaces count

    Check.suite("network: loopback never counts") {
        Check.that(!NetworkProbe.counts(name: "lo0", flags: UInt32(IFF_LOOPBACK | IFF_UP),
                                        type: UInt8(IFT_LOOP)),
                   "half a gigabyte of localhost traffic went nowhere")
    }

    Check.suite("network: tunnels never count, because their bytes are counted underneath them") {
        Check.that(!NetworkProbe.counts(name: "utun3", flags: UInt32(IFF_POINTOPOINT | IFF_UP), type: 1),
                   "a VPN tunnel")
        Check.that(!NetworkProbe.counts(name: "gif0", flags: UInt32(IFF_POINTOPOINT),
                                        type: UInt8(IFT_GIF)), "a generic tunnel")
    }

    Check.suite("network: bridges and aggregates never count, by type or by name") {
        Check.that(!NetworkProbe.counts(name: "en7", flags: 0x8863, type: UInt8(IFT_BRIDGE)),
                   "a bridge that admits to being one")
        Check.that(!NetworkProbe.counts(name: "bridge0", flags: 0x8863, type: UInt8(IFT_ETHER)),
                   "and a bridge that claims to be plain ethernet, which is what this Mac reports")
        Check.that(!NetworkProbe.counts(name: "bond0", flags: 0x8863, type: UInt8(IFT_IEEE8023ADLAG)),
                   "a link aggregate")
        Check.that(!NetworkProbe.counts(name: "vlan0", flags: 0x8863, type: UInt8(IFT_L2VLAN)),
                   "a VLAN")
    }

    Check.suite("network: real links count, including the awkward ones") {
        Check.that(NetworkProbe.counts(name: "en0", flags: 0x8863, type: UInt8(IFT_ETHER)),
                   "wifi and ethernet, obviously")
        Check.that(NetworkProbe.counts(name: "awdl0", flags: 0x8863, type: UInt8(IFT_ETHER)),
                   "AirDrop shares en0's radio but not its counters")
        Check.that(NetworkProbe.counts(name: "anpi0", flags: 0x8863, type: UInt8(IFT_ETHER)),
                   "the link to the co-processors is a real link")
        Check.that(NetworkProbe.counts(name: "en4", flags: 0, type: UInt8(IFT_ETHER)),
                   "a link that is down still counts: it contributes zero, and it may come up mid-session")
    }
}
