import CoreGraphics

/// The grid. 📐
///
/// The arithmetic that decides where things go, pulled out of the views that
/// draw them. None of these functions touch AppKit, none of them read a sample,
/// and all of them are total: hand them a nonsense chip with forty cores in one
/// cluster and they answer with a layout that is cramped but still correct.
///
/// That totality is the whole point. This Mac has one shape, and the panel has
/// to look composed on every other Mac too: a four-core M1, a twenty-core
/// Ultra, an Intel machine with one cluster and no efficiency cores. Those are
/// not shapes that can be checked by looking at the screen here, so they are
/// checked by `Tests/ActivityLayoutTests.swift` instead, and the price of that
/// is that the arithmetic must be reachable without a window.
///
/// The trap: everything here is in *flipped* view coordinates, because the
/// panel stacks downward and flipped views make that arithmetic read like the
/// design. In particular `sparkline` puts the largest value at `rect.minY`,
/// which is the top edge of a flipped view and the bottom edge of a normal one.
/// Drawing these points into an unflipped view produces an upside-down graph
/// that still looks plausible, which is the worst kind of wrong.
enum ActivityLayout {

    /// One item's position along an axis.
    struct Span: Equatable {
        var origin: CGFloat
        var length: CGFloat
    }

    // MARK: - rows of bars

    /// `count` equal bars across `width`, separated by up to `gap`, each no
    /// wider than `maximum`.
    ///
    /// The gap is the first thing sacrificed when the row is crowded: twenty
    /// cores in the space of five keep their full width and lose their
    /// separation, because a legible bar with no gap beats a gap with no bar.
    /// If even a gapless row cannot give every bar `minimum`, the bars go under
    /// it rather than overflowing the row: the panel would rather be cramped
    /// than draw outside itself.
    ///
    /// The cap is what keeps a four-core chip from drawing four slabs. A bar
    /// that shows its value by filling upward has to be taller than it is wide,
    /// or the fill reads as an underline rather than a level; past about nine
    /// points the shape stops meaning what it is supposed to mean, so the row
    /// stops growing and leaves the rest as whitespace.
    static func bars(count: Int, width: CGFloat, gap: CGFloat, minimum: CGFloat,
                     maximum: CGFloat = .greatestFiniteMagnitude) -> [Span] {
        guard count > 0, width > 0 else { return [] }
        let n = CGFloat(count)
        var g: CGFloat = count > 1 ? max(0, gap) : 0

        let capped = n * maximum + (n - 1) * g
        let width = min(width, capped)

        if count > 1, (width - g * (n - 1)) / n < minimum {
            g = max(0, (width - n * minimum) / (n - 1))
        }

        let barWidth = (width - g * (n - 1)) / n
        return (0..<count).map {
            Span(origin: CGFloat($0) * (barWidth + g), length: barWidth)
        }
    }

    // MARK: - segmented bars

    /// Widths for a stacked bar of `parts` drawn against `total` across `width`.
    ///
    /// A part that is present but tiny gets `minimumVisible` rather than
    /// vanishing: compressed memory is usually a sliver, and a sliver you
    /// cannot see reads as zero, which is exactly the dishonesty this panel is
    /// supposed to avoid. Handing out those minimums can overrun the bar, so
    /// the result is scaled back down to fit; the segments then lie slightly
    /// about their proportion in exchange for not lying about their existence.
    static func segments(_ parts: [Double], of total: Double,
                         width: CGFloat, minimumVisible: CGFloat) -> [CGFloat] {
        guard width > 0, total > 0, total.isFinite else { return parts.map { _ in 0 } }

        var out = parts.map { part -> CGFloat in
            guard part > 0, part.isFinite else { return 0 }
            return max(minimumVisible, CGFloat(part / total) * width)
        }

        let sum = out.reduce(0, +)
        if sum > width {
            out = out.map { $0 * (width / sum) }
        }
        return out
    }

    // MARK: - sparklines

    /// Points for a sparkline of `values` (oldest first) inside `rect`.
    ///
    /// The newest value sits on the right edge and the line grows leftward, so
    /// a panel that has been open for eight seconds shows an eight-second line
    /// hugging the right rather than eight points stretched across a minute.
    /// The horizontal step comes from `capacity`, not from how much has been
    /// collected, which is what makes the graph scroll instead of squash.
    ///
    /// `scale` is the value that reaches the top edge. Values above it are
    /// clamped rather than allowed to draw outside the rect.
    static func sparkline(_ values: [Double], capacity: Int,
                          in rect: CGRect, scale: Double) -> [CGPoint] {
        guard !values.isEmpty, rect.width > 0, rect.height > 0 else { return [] }

        let slots = max(capacity, values.count)
        let step = slots > 1 ? rect.width / CGFloat(slots - 1) : 0
        let last = values.count - 1

        return values.enumerated().map { index, value in
            let x = rect.maxX - CGFloat(last - index) * step
            let fraction: Double
            if scale > 0, value.isFinite {
                fraction = min(1, max(0, value / scale))
            } else {
                fraction = 0
            }
            return CGPoint(x: x, y: rect.maxY - CGFloat(fraction) * rect.height)
        }
    }

    /// A round number at or above `value`, from the 1 / 2 / 3 / 5 series.
    ///
    /// Sparkline axes are rescaled every second, and an axis that tracks the
    /// maximum exactly makes the whole graph twitch whenever the peak moves a
    /// hair. Snapping to round numbers means the axis holds still for minutes
    /// at a time and the line moves instead, which is the thing worth watching.
    ///
    /// The 3 is in the series for a reason that only shows up on screen: a Mac
    /// peaking at 26 W against a ceiling of 50 draws its whole graph in the
    /// bottom half of the rect and looks like nothing is happening. Four steps
    /// per decade keep the line using its height without making the axis
    /// restless.
    static func niceCeiling(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        let exponent = (log10(value)).rounded(.down)
        let power = pow(10.0, exponent)
        let mantissa = value / power
        let step: Double
        switch mantissa {
        case ...1.0: step = 1
        case ...2.0: step = 2
        case ...3.0: step = 3
        case ...5.0: step = 5
        default:     step = 10
        }
        return step * power
    }

    // MARK: - rows of unequal things

    /// Lay items of their own natural widths across a row, spreading whatever
    /// is left over into the gaps between them.
    ///
    /// The alternative, equal columns, is what produces "Compressed 1…" next to
    /// "App 12.1 GB" and an inch of nothing: a column wide enough for the
    /// longest label wastes that width on the shortest one. Space-between
    /// gives every item exactly what it asked for and puts the slack where it
    /// does no harm.
    ///
    /// When the items genuinely do not fit, the gaps close to `minimumGap` and
    /// the items are scaled down together, so the row stays inside itself and
    /// the truncation is shared rather than landing entirely on the last item.
    static func distribute(_ widths: [CGFloat], in width: CGFloat,
                           minimumGap: CGFloat) -> [Span] {
        guard !widths.isEmpty, width > 0 else { return [] }
        guard widths.count > 1 else {
            return [Span(origin: 0, length: min(widths[0], width))]
        }

        let natural = widths.reduce(0, +)
        let gaps = CGFloat(widths.count - 1)
        var lengths = widths
        var gap = minimumGap

        if natural + minimumGap * gaps <= width {
            gap = (width - natural) / gaps
        } else {
            let room = max(0, width - minimumGap * gaps)
            let factor = natural > 0 ? room / natural : 0
            lengths = widths.map { $0 * factor }
        }

        var origin: CGFloat = 0
        return lengths.map { length in
            let span = Span(origin: origin, length: length)
            origin += length + gap
            return span
        }
    }

    // MARK: - stacking

    /// Top edges for a column of blocks of the given heights.
    ///
    /// A zero height means a section with nothing to say, and it takes no
    /// spacing with it. That is what lets a Mac with no power counters simply
    /// not have a power section, rather than have a gap where one would be.
    static func stack(_ heights: [CGFloat], spacing: CGFloat, top: CGFloat) -> [CGFloat] {
        var origins: [CGFloat] = []
        origins.reserveCapacity(heights.count)
        var y = top
        for height in heights {
            origins.append(y)
            guard height > 0 else { continue }
            y += height + spacing
        }
        return origins
    }

    /// How tall that column ends up, including a bottom margin but not the
    /// spacing that would have followed the last block.
    static func stackHeight(_ heights: [CGFloat], spacing: CGFloat,
                            top: CGFloat, bottom: CGFloat) -> CGFloat {
        let drawn = heights.filter { $0 > 0 }
        guard !drawn.isEmpty else { return top + bottom }
        return top + drawn.reduce(0, +) + spacing * CGFloat(drawn.count - 1) + bottom
    }
}
