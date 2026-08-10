import CoreGraphics
import Foundation

/// Where things go on chips this Mac is not.
///
/// The panel is checked by eye on the machine it was written on, which has one
/// shape. Every other shape (four cores, twenty cores, one cluster, six
/// clusters) is checked here instead, which is the reason the arithmetic lives
/// in `ActivityLayout` and not inside `draw(_:)`.
func runActivityLayoutTests() {

    let epsilon: CGFloat = 0.0001

    Check.suite("layout: a row of bars fills its width exactly") {
        let spans = ActivityLayout.bars(count: 5, width: 154, gap: 3, minimum: 2)
        Check.equal(spans.count, 5, "one span per core")
        Check.close(Double(spans[0].origin), 0, tolerance: 0.0001, "the row starts at zero")
        Check.close(Double(spans[4].end), 154, tolerance: 0.0001, "and ends on the right edge")
        Check.that(Set(spans.map { (($0.length * 1000).rounded()) }).count == 1,
                   "every bar is the same width")
    }

    Check.suite("layout: bars never overlap") {
        for count in [1, 2, 3, 4, 5, 8, 14, 20, 40] {
            let spans = ActivityLayout.bars(count: count, width: 120, gap: 3, minimum: 2)
            let overlapping = zip(spans, spans.dropFirst()).contains { $0.end > $1.origin + epsilon }
            Check.that(!overlapping, "no overlap with \(count) bars")
            Check.that(spans.allSatisfy { $0.length > 0 }, "every bar has width with \(count) bars")
            Check.that((spans.last?.end ?? 0) <= 120 + epsilon, "nothing draws past the row with \(count) bars")
        }
    }

    Check.suite("layout: a single bar takes the whole row and no gap") {
        let spans = ActivityLayout.bars(count: 1, width: 100, gap: 3, minimum: 2)
        Check.equal(spans.count, 1, "one span")
        Check.close(Double(spans[0].origin), 0, tolerance: epsilon, "at the left")
        Check.close(Double(spans[0].length), 100, tolerance: epsilon, "filling the row")
    }

    Check.suite("layout: the gap is what gets sacrificed when the row is crowded") {
        // Twenty bars, three-point gaps and a four-point minimum need 137 points.
        let roomy = ActivityLayout.bars(count: 20, width: 200, gap: 3, minimum: 4)
        Check.close(Double(roomy[1].origin - roomy[0].end), 3, tolerance: epsilon,
                    "a roomy row keeps its full gap")

        let tight = ActivityLayout.bars(count: 20, width: 100, gap: 3, minimum: 4)
        let tightGap = tight[1].origin - tight[0].end
        Check.that(tightGap >= -epsilon && tightGap < 3, "a tight row shrinks the gap first")
        Check.that(tight.allSatisfy { $0.length >= 4 - epsilon }, "and keeps the bars legible")
        Check.close(Double(tight[19].end), 100, tolerance: epsilon, "still filling the row exactly")
    }

    Check.suite("layout: an impossible row stays inside itself") {
        // Forty bars in sixty points cannot all be four points wide.
        let spans = ActivityLayout.bars(count: 40, width: 60, gap: 3, minimum: 4)
        Check.equal(spans.count, 40, "no core is dropped")
        Check.close(Double(spans[39].end), 60, tolerance: epsilon,
                    "cramped, but never drawn outside the row")
        Check.that(spans.allSatisfy { $0.length > 0 }, "and every bar still exists")
    }

    Check.suite("layout: degenerate rows") {
        Check.equal(ActivityLayout.bars(count: 0, width: 100, gap: 3, minimum: 2).count, 0,
                    "no cores, no bars")
        Check.equal(ActivityLayout.bars(count: 4, width: 0, gap: 3, minimum: 2).count, 0,
                    "no room, no bars")
        Check.equal(ActivityLayout.bars(count: -1, width: 100, gap: 3, minimum: 2).count, 0,
                    "a negative core count is not a row")
    }

    Check.suite("layout: one slot width serves every cluster on a chip") {
        // The comb is divided by the largest cluster's core count and every row
        // uses those slots, so core positions line up down the rows and a short
        // cluster leaves its last slot empty rather than drawing wider bars.
        let slots = ActivityLayout.bars(count: 5, width: 154, gap: 3, minimum: 2, maximum: 9)
        let fourCoreRow = Array(slots.prefix(4))
        Check.equal(fourCoreRow.count, 4, "a four-core cluster fills four of the five slots")
        Check.that(fourCoreRow.last!.end < slots[4].origin, "and leaves the fifth empty")
        Check.that(Set(slots.map { ($0.length * 1000).rounded() }).count == 1,
                   "every row therefore draws bars of identical width")
    }

    Check.suite("layout: the cap keeps a bar taller than it is wide") {
        let roomy = ActivityLayout.bars(count: 4, width: 154, gap: 3, minimum: 2, maximum: 9)
        Check.that(roomy.allSatisfy { $0.length <= 9 + epsilon },
                   "four cores do not become four slabs")
        Check.close(Double(roomy[3].end), 4 * 9 + 3 * 3, tolerance: epsilon,
                    "the row is only as wide as the cap allows, and the rest is whitespace")

        let crowded = ActivityLayout.bars(count: 20, width: 154, gap: 3, minimum: 2, maximum: 9)
        Check.close(Double(crowded[19].end), 154, tolerance: epsilon,
                    "a crowded row still uses everything it is given")
        Check.that(crowded.allSatisfy { $0.length < 9 }, "and stays under the cap on its own")

        let uncapped = ActivityLayout.bars(count: 4, width: 154, gap: 3, minimum: 2)
        Check.close(Double(uncapped[3].end), 154, tolerance: epsilon,
                    "without a cap the row fills its width, which is what meters want")
    }

    Check.suite("layout: memory segments never overrun the bar") {
        let widths = ActivityLayout.segments([12.0, 4.8, 1.5], of: 24, width: 288, minimumVisible: 2)
        Check.that(widths.reduce(0, +) <= 288 + epsilon, "the stack fits")
        Check.close(Double(widths[0]), Double(288 * 12.0 / 24.0), tolerance: 0.01,
                    "apps take their share")
        Check.that(widths[0] > widths[1] && widths[1] > widths[2], "and the order of sizes holds")
    }

    Check.suite("layout: a sliver of compressed memory is still visible") {
        let widths = ActivityLayout.segments([8.0, 2.0, 0.001], of: 24, width: 288, minimumVisible: 2)
        Check.that(widths[2] >= 2 - epsilon, "a present-but-tiny segment gets a minimum width")

        let absent = ActivityLayout.segments([8.0, 2.0, 0.0], of: 24, width: 288, minimumVisible: 2)
        Check.close(Double(absent[2]), 0, tolerance: epsilon,
                    "an absent segment gets nothing, so nothing is drawn as something")
    }

    Check.suite("layout: segments that would overflow are scaled back to fit") {
        let widths = ActivityLayout.segments([20.0, 20.0, 20.0], of: 24, width: 288, minimumVisible: 2)
        Check.close(Double(widths.reduce(0, +)), 288, tolerance: 0.01, "scaled down to exactly the bar")

        let many = ActivityLayout.segments(Array(repeating: 0.0001, count: 200),
                                           of: 24, width: 100, minimumVisible: 2)
        Check.that(many.reduce(0, +) <= 100 + epsilon,
                   "two hundred minimums still cannot overrun the bar")
    }

    Check.suite("layout: segments with nothing to divide by") {
        let widths = ActivityLayout.segments([1.0, 2.0], of: 0, width: 288, minimumVisible: 2)
        Check.equal(widths, [0, 0], "no total means no bar rather than an infinite one")
    }

    Check.suite("layout: a sparkline hugs the right until it has a minute") {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 30)

        let empty = ActivityLayout.sparkline([], capacity: 60, in: rect, scale: 10)
        Check.equal(empty.count, 0, "nothing recorded, nothing drawn")

        let one = ActivityLayout.sparkline([5], capacity: 60, in: rect, scale: 10)
        Check.equal(one.count, 1, "one sample, one point")
        Check.close(Double(one[0].x), 120, tolerance: epsilon, "pinned to the right edge, which is now")
        Check.close(Double(one[0].y), 15, tolerance: epsilon, "half of the scale is half the height")

        let eight = ActivityLayout.sparkline(Array(repeating: 5, count: 8),
                                             capacity: 60, in: rect, scale: 10)
        Check.close(Double(eight.last!.x), 120, tolerance: epsilon, "newest is still now")
        Check.that(eight[0].x > 100, "eight seconds of history occupy eight seconds of width, not sixty")
    }

    Check.suite("layout: a full sparkline spans the rect") {
        let rect = CGRect(x: 10, y: 4, width: 120, height: 30)
        let points = ActivityLayout.sparkline(Array(repeating: 5, count: 60),
                                              capacity: 60, in: rect, scale: 10)
        Check.equal(points.count, 60, "a point per sample")
        Check.close(Double(points[0].x), 10, tolerance: epsilon, "oldest on the left edge")
        Check.close(Double(points[59].x), 130, tolerance: epsilon, "newest on the right edge")
    }

    Check.suite("layout: the sparkline is drawn for a flipped view") {
        let rect = CGRect(x: 0, y: 100, width: 60, height: 40)
        let points = ActivityLayout.sparkline([0, 10, 5], capacity: 3, in: rect, scale: 10)
        Check.close(Double(points[0].y), 140, tolerance: epsilon, "zero sits on the bottom edge")
        Check.close(Double(points[1].y), 100, tolerance: epsilon, "the scale sits on the top edge")
        Check.close(Double(points[2].y), 120, tolerance: epsilon, "and half sits halfway")
    }

    Check.suite("layout: a sparkline cannot draw outside its rect") {
        let rect = CGRect(x: 0, y: 0, width: 60, height: 40)
        let points = ActivityLayout.sparkline([-5, 1000, .nan], capacity: 3, in: rect, scale: 10)
        Check.that(points.allSatisfy { $0.y >= -epsilon && $0.y <= 40 + epsilon },
                   "over-scale, negative and NaN values are all clamped into the rect")

        let flat = ActivityLayout.sparkline([1, 2, 3], capacity: 3, in: rect, scale: 0)
        Check.that(flat.allSatisfy { $0.y == 40 }, "no scale means a flat line on the floor")
    }

    Check.suite("layout: sparkline axes snap to round numbers") {
        Check.close(ActivityLayout.niceCeiling(0.07), 0.1, tolerance: 0.0001, "a tenth")
        Check.close(ActivityLayout.niceCeiling(1), 1, tolerance: 0.0001, "already round")
        Check.close(ActivityLayout.niceCeiling(1.0001), 2, tolerance: 0.0001, "just over one")
        Check.close(ActivityLayout.niceCeiling(2.4), 3, tolerance: 0.0001, "up to three")
        Check.close(ActivityLayout.niceCeiling(3.2), 5, tolerance: 0.0001, "up to five")
        Check.close(ActivityLayout.niceCeiling(26.5), 30, tolerance: 0.0001,
                    "a peak of 26 gets a ceiling of 30, not one of 50 that halves the graph")
        Check.close(ActivityLayout.niceCeiling(14), 20, tolerance: 0.0001, "up to twenty")
        Check.close(ActivityLayout.niceCeiling(20), 20, tolerance: 0.0001, "and stays there")
        Check.close(ActivityLayout.niceCeiling(99), 100, tolerance: 0.0001, "up to a hundred")
        Check.close(ActivityLayout.niceCeiling(118_000), 200_000, tolerance: 1, "and at any magnitude")
        Check.close(ActivityLayout.niceCeiling(0), 0, tolerance: 0.0001, "nothing has no axis")
        Check.close(ActivityLayout.niceCeiling(-3), 0, tolerance: 0.0001, "and neither has nonsense")
    }

    Check.suite("layout: an axis that holds still while the line moves") {
        // The reason for snapping: a peak drifting from 13.9 to 14.4 W must not
        // rescale the graph under the line.
        let axes = [13.9, 14.0, 14.4, 15.2, 19.8].map(ActivityLayout.niceCeiling)
        Check.that(Set(axes).count == 1, "a whole watt of drift does not move the axis")
    }

    Check.suite("layout: a row of unequal labels spreads its slack") {
        let spans = ActivityLayout.distribute([60, 62, 96], in: 288, minimumGap: 8)
        Check.equal(spans.count, 3, "one span per item")
        Check.close(Double(spans[0].origin), 0, tolerance: epsilon, "first item is flush left")
        Check.close(Double(spans[2].end), 288, tolerance: epsilon, "last item is flush right")
        Check.equal(spans.map(\.length), [60, 62, 96],
                    "and every item keeps the width it asked for, so nothing truncates")
        let gapA = spans[1].origin - spans[0].end
        let gapB = spans[2].origin - spans[1].end
        Check.close(Double(gapA), Double(gapB), tolerance: epsilon, "the slack is shared evenly")
    }

    Check.suite("layout: a row that genuinely does not fit shares the loss") {
        let spans = ActivityLayout.distribute([200, 200], in: 100, minimumGap: 8)
        Check.that(spans[1].end <= 100 + epsilon, "the row stays inside itself")
        Check.close(Double(spans[0].length), Double(spans[1].length), tolerance: epsilon,
                    "both items shrink, rather than the last one taking all the truncation")
        Check.close(Double(spans[1].origin - spans[0].end), 8, tolerance: epsilon,
                    "and the gap closes to its minimum first")
    }

    Check.suite("layout: degenerate rows of labels") {
        Check.equal(ActivityLayout.distribute([], in: 288, minimumGap: 8).count, 0, "no items")
        let one = ActivityLayout.distribute([40], in: 288, minimumGap: 8)
        Check.equal(one, [ActivityLayout.Span(origin: 0, length: 40)], "a lone item is flush left")
        let wide = ActivityLayout.distribute([400], in: 288, minimumGap: 8)
        Check.close(Double(wide[0].length), 288, tolerance: epsilon, "and clipped to the row")
    }

    Check.suite("layout: stacking sections") {
        let origins = ActivityLayout.stack([30, 70, 40], spacing: 18, top: 16)
        Check.equal(origins, [16, 64, 152], "each section sits below the last, plus the gap")
        Check.close(Double(ActivityLayout.stackHeight([30, 70, 40], spacing: 18, top: 16, bottom: 16)),
                    16 + 140 + 36 + 16, tolerance: epsilon,
                    "the trailing gap is not counted")
    }

    Check.suite("layout: a section with nothing to say leaves no gap") {
        let origins = ActivityLayout.stack([30, 0, 40], spacing: 18, top: 16)
        Check.equal(origins, [16, 64, 64], "the empty section takes no space and no spacing")
        Check.close(Double(ActivityLayout.stackHeight([30, 0, 40], spacing: 18, top: 16, bottom: 16)),
                    16 + 70 + 18 + 16, tolerance: epsilon, "and the panel gets shorter, not gappier")
    }

    Check.suite("layout: a panel with nothing at all to say") {
        Check.equal(ActivityLayout.stack([], spacing: 18, top: 16), [], "no sections, no origins")
        Check.close(Double(ActivityLayout.stackHeight([0, 0], spacing: 18, top: 16, bottom: 16)),
                    32, tolerance: epsilon, "margins only")
    }
}
