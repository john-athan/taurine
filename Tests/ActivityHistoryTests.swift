import Foundation

/// The minute the panel remembers.
///
/// A ring buffer is three lines of code and four ways to be off by one, and
/// every one of them looks like a plausible graph. These check the seam: the
/// order after a wrap, which value is newest, and what the window forgets.
func runActivityHistoryTests() {

    Check.suite("history: an empty buffer says nothing") {
        let h = ActivityHistory(capacity: 60)
        Check.equal(h.count, 0, "nothing recorded")
        Check.equal(h.ordered.count, 0, "and it says so")
        Check.equal(h.ordered, [], "no values to draw")
        Check.isNil(h.ordered.last, "no latest value")
        Check.isNil(h.maximum, "and no maximum to scale an axis by")
    }

    Check.suite("history: capacity is at least one") {
        Check.equal(ActivityHistory(capacity: 0).capacity, 1, "zero would divide by zero later")
        Check.equal(ActivityHistory(capacity: -5).capacity, 1, "so would a negative")
        Check.equal(ActivityHistory().capacity, ActivityHistory.oneMinute,
                    "the default is the minute the panel promises")
        Check.equal(ActivityHistory.oneMinute, 60, "sixty samples at one per second")
    }

    Check.suite("history: partially filled, oldest first") {
        var h = ActivityHistory(capacity: 5)
        h.append(1); h.append(2); h.append(3)
        Check.equal(h.count, 3, "three of five slots used")
        Check.equal(h.ordered, [1, 2, 3], "in the order they arrived")
        Check.equal(h.ordered.last, 3, "the newest is the last one appended")
        Check.equal(h.maximum, 3, "the largest so far")
    }

    Check.suite("history: exactly full") {
        var h = ActivityHistory(capacity: 4)
        for v in [1.0, 2, 3, 4] { h.append(v) }
        Check.equal(h.count, 4, "full")
        Check.equal(h.ordered, [1, 2, 3, 4], "no seam yet")
        Check.equal(h.ordered.last, 4, "newest")
    }

    Check.suite("history: the wrap, where the seam would be") {
        var h = ActivityHistory(capacity: 4)
        for v in [1.0, 2, 3, 4, 5] { h.append(v) }
        Check.equal(h.count, 4, "capacity is a hard ceiling")
        Check.equal(h.ordered, [2, 3, 4, 5], "the oldest was evicted, the rest kept their order")
        Check.equal(h.ordered.last, 5, "newest survives the wrap")

        h.append(6)
        Check.equal(h.ordered, [3, 4, 5, 6], "and again")
        Check.equal(h.ordered.last, 6, "still newest")

        // All the way around, so the write head lands back on slot zero.
        for v in [7.0, 8, 9, 10] { h.append(v) }
        Check.equal(h.ordered, [7, 8, 9, 10], "a whole lap leaves the order intact")
        Check.equal(h.ordered.last, 10, "and the head back where it started")
    }

    Check.suite("history: a spike leaves the axis when it leaves the graph") {
        var h = ActivityHistory(capacity: 3)
        h.append(100); h.append(1); h.append(2)
        Check.equal(h.maximum, 100, "still inside the window")
        h.append(3)
        Check.equal(h.maximum, 3, "evicted, so it no longer scales the axis")
    }

    Check.suite("history: nonsense values cannot flatten the graph") {
        var h = ActivityHistory(capacity: 4)
        h.append(.infinity)
        h.append(.nan)
        h.append(-7)
        h.append(5)
        Check.equal(h.ordered, [0, 0, 0, 5], "infinities, NaNs and negatives all record as zero")
        Check.equal(h.maximum, 5, "so one bad sample does not own the axis for a minute")
    }

    Check.suite("history: a capacity of one keeps only the present") {
        var h = ActivityHistory(capacity: 1)
        h.append(1); h.append(2)
        Check.equal(h.ordered, [2], "one slot, latest wins")
        Check.equal(h.ordered.last, 2, "and it is the latest")
    }

    Check.suite("history: closing the panel forgets the minute") {
        var h = ActivityHistory(capacity: 3)
        for v in [1.0, 2, 3, 4] { h.append(v) }
        h.forget()
        Check.equal(h.count, 0, "nothing survives the close")
        Check.equal(h.ordered, [], "no stale values to draw")
        Check.isNil(h.ordered.last, "and no stale latest")

        // The head must have been reset too, or the next lap comes out rotated.
        h.append(9); h.append(8)
        Check.equal(h.ordered, [9, 8], "the next session starts clean")
    }
}
