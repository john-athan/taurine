import Cocoa

/// The bill. ⚡
///
/// The number people open this panel for, and the only place the accent colour
/// is spent on data. Everything above and below it is greys at eleven points;
/// this is thirty points of Taurine red with a minute of history beside it. If
/// somebody glances at the panel for half a second, this is what they should
/// come away with.
///
/// The headline is split into a monospaced number and a small proportional
/// unit, drawn separately. `"14.2 W"` set entirely at thirty points wastes a
/// third of the width on a capital W and makes the digits smaller than they
/// need to be; setting the unit at thirteen points and hanging it off the
/// number's own measured width buys back the room for the sparkline.
///
/// The sparkline's axis is snapped to a round ceiling rather than tracking the
/// observed peak, because a scale that re-fits itself every second makes the
/// line twitch when the machine is steady. The number on the title row is the
/// peak, not that ceiling: the ceiling is a drawing decision and the peak is a
/// measurement, and since the peak is by definition the highest point on the
/// line, it labels the tallest thing in the graph, which is the one place a
/// reader looks when they want a number off it.
///
/// The trap: `totalWatts` is not always the sum of the parts. When the chip
/// publishes a package counter that is the headline, and it includes fabric and
/// memory controller draw that no individual part accounts for, so CPU + GPU +
/// ANE will visibly fail to add up. Rather than hide that, the title row names
/// which of the two the headline is, so a reader doing the arithmetic finds an
/// explanation instead of a bug.
final class ActivityPowerView: ActivitySectionView {

    private static let heroHeight: CGFloat = 40
    private static let partsHeight: CGFloat = 16
    private static let sparklineInset: CGFloat = 12

    private var power: PowerActivity?
    private var history = ActivityHistory()

    init() { super.init(title: "POWER") }

    /// `take` refuses anything that is not a readable wattage, so holding a
    /// sample at all is the same statement as having something to draw.
    override var hasContent: Bool { power != nil }
    override var bodyHeight: CGFloat { Self.heroHeight + Self.partsHeight }

    override var titleValue: String? {
        guard let peak = history.maximum, history.count > 1 else { return sourceNote }
        guard let note = sourceNote else { return "peak \(ActivityFormat.watts(peak))" }
        return "\(note)   peak \(ActivityFormat.watts(peak))"
    }

    /// Which number the headline is, when the chip gives us a choice.
    private var sourceNote: String? {
        guard let power else { return nil }
        return power.packageWatts != nil ? "package" : nil
    }

    override var spokenValue: String { power.map(ActivitySpeech.power) ?? "" }

    /// The one gate on this tile. A headline that is not a number is not a
    /// reading, so it is refused here rather than downstream, where three
    /// separate things would each have to cope with it and would each have to
    /// agree: `hasContent` would say the tile has something to show, the
    /// history would record the NaN as a zero and print "peak 0.00 W" beside
    /// it, and the headline would draw "n/a" in thirty points of accent red
    /// with a " W" welded on. Refusing the sample leaves the tile exactly as a
    /// Mac with no energy counters leaves it: absent, and the panel shorter.
    override func take(_ sample: ActivitySample) {
        guard let power = sample.power, let total = power.totalWatts,
              total.isFinite, total >= 0 else { return }
        self.power = power
        history.append(total)
    }

    override func forget() {
        power = nil
        history.forget()
    }

    override func drawBody(in rect: CGRect) {
        guard let power, let total = power.totalWatts,
              let number = ActivityFormat.wattsNumber(total) else { return }

        let hero = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: Self.heroHeight)
        let numberWidth = drawHeadline(number, in: hero)

        let left = hero.minX + numberWidth + Self.sparklineInset
        let graph = CGRect(x: left, y: hero.minY + 5, width: hero.maxX - left, height: hero.height - 10)
        drawSparkline(in: graph)

        drawParts(power, in: CGRect(x: rect.minX, y: hero.maxY,
                                    width: rect.width, height: Self.partsHeight))
    }

    /// Draws "14.2" big and " W" small, and reports how much room the pair took.
    ///
    /// The number comes from the formatter already separated from its unit.
    /// Taking `"14.2 W"` apart afterwards worked until the day the value was
    /// not a number: `"n/a"` has no unit to strip, so the tile printed "n/a"
    /// and welded a red " W" onto it. `take` no longer lets such a value in,
    /// and asking for the digits directly means there is no string surgery left
    /// to get wrong if it ever did.
    private func drawHeadline(_ number: String, in rect: CGRect) -> CGFloat {
        let accent = ActivityTheme.accent

        let numberWidth = ActivityDraw.width(number, font: ActivityTheme.hero)
        ActivityDraw.text(number, font: ActivityTheme.hero, color: accent,
                          in: CGRect(x: rect.minX, y: rect.minY,
                                     width: numberWidth, height: rect.height))

        let unit = " W"
        let unitWidth = ActivityDraw.width(unit, font: ActivityTheme.heroUnit)
        // Sit the unit on the number's baseline rather than its centre, which
        // is what makes the pair read as one word instead of two elements.
        let baselineDrop = (ActivityTheme.hero.capHeight - ActivityTheme.heroUnit.capHeight) / 2
        ActivityDraw.text(unit, font: ActivityTheme.heroUnit,
                          color: accent.withAlphaComponent(0.75),
                          in: CGRect(x: rect.minX + numberWidth, y: rect.minY + baselineDrop,
                                     width: unitWidth, height: rect.height))

        return numberWidth + unitWidth
    }

    private func drawSparkline(in rect: CGRect) {
        guard rect.width > 20 else { return }
        let values = history.ordered
        // A floor on the axis: an idle Mac drifting between 0.4 and 0.6 W would
        // otherwise be drawn as a mountain range.
        let scale = max(ActivityLayout.niceCeiling(history.maximum ?? 0), 1)
        let points = ActivityLayout.sparkline(values, capacity: history.capacity,
                                              in: rect, scale: scale)

        ActivityTheme.track.setFill()
        CGRect(x: rect.minX, y: rect.maxY - 0.5, width: rect.width, height: 0.5).fill()

        ActivityDraw.sparkline(points, in: rect, stroke: ActivityTheme.accent,
                               fillAlpha: 0.15, lineWidth: 1.6, dot: true)
    }

    private func drawParts(_ power: PowerActivity, in rect: CGRect) {
        let parts: [(String, Double)] = [("CPU", power.cpuWatts),
                                         ("GPU", power.gpuWatts),
                                         ("ANE", power.aneWatts)]
            .compactMap { name, watts in watts.map { (name, $0) } }
        guard !parts.isEmpty else { return }

        let gap: CGFloat = 6
        let labels = parts.map { ActivityDraw.width($0.0, font: ActivityTheme.title,
                                                    kern: ActivityTheme.titleKern) }
        let values = parts.map { ActivityDraw.width(ActivityFormat.watts($0.1),
                                                    font: ActivityTheme.value) }
        let spans = ActivityLayout.distribute(zip(labels, values).map { $0 + gap + $1 },
                                              in: rect.width, minimumGap: 10)

        for (index, part) in parts.enumerated() {
            let x = rect.minX + spans[index].origin
            ActivityDraw.text(part.0, font: ActivityTheme.title, color: ActivityTheme.chrome,
                              in: CGRect(x: x, y: rect.minY,
                                         width: labels[index], height: rect.height),
                              kern: ActivityTheme.titleKern)
            let valueX = x + labels[index] + gap
            ActivityDraw.text(ActivityFormat.watts(part.1), font: ActivityTheme.value,
                              color: .labelColor,
                              in: CGRect(x: valueX, y: rect.minY,
                                         width: max(0, x + spans[index].length - valueX),
                                         height: rect.height))
        }
    }
}
