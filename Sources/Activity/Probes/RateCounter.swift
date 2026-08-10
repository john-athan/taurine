import Foundation

/// The odometer. 🧮
///
/// Three of the six probes ask the kernel the same shape of question: give me a
/// number that only ever goes up, and I will tell you how fast it is going up.
/// Doing that correctly is four lines and one trap, so it lives here once
/// instead of three times.
///
/// The trap is the baseline. A cumulative counter carries no information on its
/// own; the rate is the difference between two readings, so the first reading is
/// not a measurement at all. Reporting zero for it would put a fake data point
/// at the left edge of every graph. `advance` returns nil until it has something
/// to subtract from, and every probe that owns one takes that first reading in
/// `open()`, which is what keeps the nil off the screen.
///
/// A counter that goes backwards means exactly one thing: the thing being
/// counted was replaced. A disk detached and its `IOBlockStorageDriver`
/// statistics went with it; an interface was destroyed and made again under the
/// same name. There is no arithmetic that recovers the missing bytes, so the
/// honest answer is no answer for that one tick.
///
/// It used to mean two things, and this type carried a `modulus` to tell them
/// apart: `if_data.ifi_ibytes`, the interface counter `getifaddrs` publishes, is
/// `u_int32_t` and rolls over every 4 GiB. Reconstructing that roll-over was
/// only ever compensation for reading a narrow counter while a wide one existed.
/// `NetworkProbe` reads the 64 bit counters now, so the second cause is gone and
/// the parameter went with it.
struct RateCounter {

    private var previous: UInt64?

    /// Spelled out because the storage is private, which would otherwise make
    /// the compiler's memberwise initialiser private too.
    init() {}

    /// False until the first reading has been taken.
    var hasBaseline: Bool { previous != nil }

    /// Take a reading. Returns how far the counter moved since the previous
    /// one, or nil when that question has no honest answer.
    ///
    /// A reading that did not move returns zero, which is a real measurement
    /// and must not be confused with the nil above.
    @discardableResult
    mutating func advance(to reading: UInt64) -> UInt64? {
        defer { self.previous = reading }
        guard let last = previous, reading >= last else { return nil }
        return reading - last
    }
}

/// One source's pair of cumulative byte counters, named from the machine's
/// point of view: inbound is read from the device or received from the wire.
struct ByteCounters {
    var inbound: UInt64
    var outbound: UInt64
}

/// The books. 📚
///
/// Disks and network interfaces are not one counter each, they are a shifting
/// set of counters: a USB drive is plugged in, a VPN comes up, a Thunderbolt
/// dock goes away. The naive shape is to add the counters up and rate the sum,
/// and it is wrong in a way that is invisible until it is embarrassing. Plug in
/// a disk whose lifetime counter reads nine gigabytes and the summed counter
/// jumps nine gigabytes in one tick, so the panel claims a nine gigabyte per
/// second write. Unplug it and the sum falls off a cliff.
///
/// So each source gets its own `RateCounter` and the *deltas* are summed, never
/// the readings. A source seen for the first time contributes a baseline and
/// nothing else, which is also the truthful answer: bytes that crossed it
/// before it existed did not cross it during the second we are measuring. A
/// source that disappears simply stops being asked, and the bytes it already
/// contributed stay in the running total.
///
/// One source moving backwards taints the whole tick and the ledger reports
/// nothing, rather than quietly leaving that disk's traffic out of a number the
/// panel presents as the total.
struct TrafficLedger<Source: Hashable> {

    private var counters: [Source: (inbound: RateCounter, outbound: RateCounter)] = [:]
    private var inboundTotal: UInt64 = 0
    private var outboundTotal: UInt64 = 0
    private var seeded = false

    /// Spelled out for the same reason as `RateCounter.init`: private storage
    /// would otherwise hide the compiler's memberwise initialiser.
    init() {}

    /// Fold one tick's readings in. Returns the rate to publish, or nil when
    /// this tick cannot carry one: no baseline yet, no elapsed time, or a
    /// source that moved backwards.
    ///
    /// The probes call this once from `open()` with an interval of zero, which
    /// is the call that lays down the baseline and seeds the totals.
    mutating func update(_ readings: [Source: ByteCounters],
                         over interval: TimeInterval) -> TrafficRate? {
        let hadBaseline = seeded
        var inbound: UInt64 = 0
        var outbound: UInt64 = 0
        var tainted = false

        // Rebuilt rather than mutated, so a source that vanished takes its
        // counter with it and the dictionary cannot grow without bound over a
        // long session of docks coming and going.
        var next: [Source: (inbound: RateCounter, outbound: RateCounter)] = [:]
        next.reserveCapacity(readings.count)

        for (source, reading) in readings {
            var pair = counters[source] ?? (inbound: RateCounter(), outbound: RateCounter())
            let known = pair.inbound.hasBaseline
            let deltaIn = pair.inbound.advance(to: reading.inbound)
            let deltaOut = pair.outbound.advance(to: reading.outbound)
            next[source] = pair

            guard known else { continue }
            if let deltaIn, let deltaOut {
                inbound += deltaIn
                outbound += deltaOut
            } else {
                tainted = true
            }
        }
        counters = next

        if seeded {
            inboundTotal += inbound
            outboundTotal += outbound
        } else {
            // The published total starts life as the machine's own lifetime
            // figure, so it agrees with `netstat -ib` and `iostat` on the first
            // frame, and then tracks forward by measured deltas only.
            inboundTotal = readings.values.reduce(0) { $0 + $1.inbound }
            outboundTotal = readings.values.reduce(0) { $0 + $1.outbound }
            seeded = true
        }

        guard hadBaseline, interval > 0, !tainted else { return nil }
        return TrafficRate(inboundBytesPerSecond: Double(inbound) / interval,
                           outboundBytesPerSecond: Double(outbound) / interval,
                           inboundTotal: inboundTotal,
                           outboundTotal: outboundTotal)
    }

    /// Forget every source and every total, for `close()`.
    mutating func forget() {
        counters.removeAll()
        inboundTotal = 0
        outboundTotal = 0
        seeded = false
    }
}
