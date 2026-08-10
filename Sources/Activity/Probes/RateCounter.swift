import Foundation

/// The odometer. 🧮
///
/// Three of the six probes ask the kernel the same shape of question: give me a
/// number that only ever goes up, and I will tell you how fast it is going up.
/// Doing that correctly is four lines and two traps, so it lives here once
/// instead of three times.
///
/// The first trap is the baseline. A cumulative counter carries no information
/// on its own; the rate is the difference between two readings, so the first
/// reading of a session is not a measurement at all. Reporting zero for it
/// would put a fake data point at the left edge of every graph. `advance`
/// returns nil until it has something to subtract from.
///
/// The second trap is the counter going backwards, and it has two quite
/// different causes that need quite different answers:
///
///   • **Wrap.** `if_data.ifi_ibytes`, the interface counter `getifaddrs`
///     publishes, is `u_int32_t`. Verified on this machine: the field is four
///     bytes wide, so a link wraps every 4 GiB, which on a gigabit transfer is
///     every thirty-four seconds. That is not an error, it is arithmetic, and
///     the true delta is recoverable exactly because the modulus is known.
///     Pass `modulus: 1 << 32` and a backwards step is read as one wrap.
///
///   • **Reset.** A disk detaches and its `IOBlockStorageDriver` statistics go
///     with it. There is no modulus to reconstruct from, so the only honest
///     answer is no answer. Leave `modulus` nil and a backwards step reports
///     nothing for that tick.
///
/// The mistake to avoid is picking one behaviour for both. Treating a wrapped
/// interface as a reset blanks the network tile every half minute under load;
/// treating a reset disk as a wrap invents four gigabytes of traffic that never
/// happened. Which one a counter is, is a property of the counter, so the
/// caller states it.
struct RateCounter {

    /// The value the counter rolls over at, or nil for a counter wide enough
    /// that only a reset can send it backwards.
    let modulus: UInt64?

    private var previous: UInt64?

    init(modulus: UInt64? = nil) {
        self.modulus = modulus
    }

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
        guard let last = previous else { return nil }
        if reading >= last { return reading - last }
        // Backwards. One wrap of a known modulus is exact arithmetic; more than
        // one wrap in a single interval (over 4 GiB/s on a 32 bit counter) would
        // undercount, and nothing on a Mac moves that fast through one link.
        guard let modulus, last < modulus else { return nil }
        return (modulus - last) + reading
    }

    /// Drop the baseline, so the next reading is a baseline again. This is what
    /// `close()` owes the lifecycle contract: a reopened probe must not measure
    /// against a number from the last time somebody looked.
    mutating func forget() { previous = nil }
}

/// One source's pair of cumulative byte counters, named from the machine's
/// point of view: inbound is read from the device or received from the wire.
struct ByteCounters: Equatable {
    var inbound: UInt64
    var outbound: UInt64

    init(inbound: UInt64, outbound: UInt64) {
        self.inbound = inbound
        self.outbound = outbound
    }
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
/// One source moving backwards with no modulus to explain it taints the whole
/// tick and the ledger reports nothing, rather than quietly leaving that disk's
/// traffic out of a number the panel presents as the total.
struct TrafficLedger<Source: Hashable> {

    private let modulus: UInt64?
    private var counters: [Source: (inbound: RateCounter, outbound: RateCounter)] = [:]
    private var inboundTotal: UInt64 = 0
    private var outboundTotal: UInt64 = 0
    private var seeded = false

    /// `modulus` is handed to every counter in the ledger, because every source
    /// in one ledger is read through the same kernel interface and therefore
    /// has the same width.
    init(modulus: UInt64? = nil) {
        self.modulus = modulus
    }

    /// Fold one tick's readings in. Returns the rate to publish, or nil when
    /// this tick cannot carry one: no baseline yet, no elapsed time, or a
    /// source that moved backwards inexplicably.
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
            var pair = counters[source]
                ?? (inbound: RateCounter(modulus: modulus), outbound: RateCounter(modulus: modulus))
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
