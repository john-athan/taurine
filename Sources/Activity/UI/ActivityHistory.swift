import Foundation

/// The last minute. ⏳
///
/// A fixed-size ring of samples, one per second, owned by the view that draws
/// the sparkline from it. Sixty slots, because the panel promises "the last
/// minute" and a monitor that quietly kept ten is lying about its own axis.
///
/// It is a struct on purpose. Each sparkline wants its own independent window
/// (power, disk read, disk write, network in, network out) and value semantics
/// mean five of these are five plain stored properties rather than five
/// allocations with five chances to alias each other.
///
/// The trap: `storage` is not in chronological order once the ring has wrapped,
/// and reading it directly gives a sparkline with a seam in the middle where
/// the write head is. Everything that reads must go through `ordered`, which is
/// the only place that knows where the head sits; in particular `storage.last`
/// is the newest value only until the first wrap and is off by one for the rest
/// of the session, while `ordered.last` is right throughout.
struct ActivityHistory {

    /// Sixty samples at the panel's one-second interval.
    static let oneMinute = 60

    let capacity: Int

    private var storage: [Double] = []
    /// Index of the oldest value, once the ring is full. Meaningless before.
    private var head = 0

    /// How many values are actually stored, which is less than `capacity`
    /// until the panel has been open for a minute.
    var count: Int { storage.count }

    init(capacity: Int = ActivityHistory.oneMinute) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    /// Record one sample, evicting the oldest once the ring is full.
    ///
    /// Values are clamped to zero and up. A rate probe that divides by a zero
    /// interval can hand us an infinity, and one infinity would flatten the
    /// whole sparkline against the floor for the next minute.
    mutating func append(_ value: Double) {
        let v = value.isFinite ? max(0, value) : 0
        if storage.count < capacity {
            storage.append(v)
        } else {
            storage[head] = v
            head = (head + 1) % capacity
        }
    }

    /// Every stored value, oldest first.
    var ordered: [Double] {
        guard storage.count == capacity, head != 0 else { return storage }
        return Array(storage[head...]) + Array(storage[..<head])
    }

    /// The largest value inside the window. Values that have been evicted do
    /// not count, so a spike scrolls off the axis at the same moment it
    /// scrolls off the graph.
    var maximum: Double? { storage.max() }

    /// Throw the minute away. Called when the panel closes: a graph of the last
    /// minute is a lie if the app was not watching for that minute.
    mutating func forget() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}
