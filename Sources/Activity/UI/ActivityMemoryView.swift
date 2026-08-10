import Cocoa

/// The ledger. 🧠
///
/// One bar showing where the RAM went, split into the three categories that
/// behave differently: apps, which you can quit; wired, which you cannot; and
/// compressed, which is the kernel already working to avoid swapping. The
/// remainder of the bar is free memory, drawn as track.
///
/// The three segments are a monochrome ramp rather than three hues. Colour in
/// this panel means "look here", and it is already spent on the watts; three
/// coloured blocks would out-shout the number they sit under. A ramp from solid
/// to faint reads in the same order without competing, and it survives dark
/// mode and increased contrast without a second palette.
///
/// The swap line appears only when swap is in use, and once it appears it
/// stays for the rest of the session. Swapping is the fact people are looking
/// for when they check memory, and a line that blinked in and out as the value
/// crossed zero would be both distracting and, one frame later, wrong.
///
/// The trap: `cached` is deliberately not drawn. It is file-backed memory the
/// kernel hands straight back when anything asks, so including it in the used
/// bar would show a machine with 4 GB genuinely free as nearly full, which is
/// the single most common way memory readouts mislead. `used` here is app +
/// wired + compressed, the same arithmetic Activity Monitor calls "Memory
/// Used", and the segments add up to exactly that bar and no more.
final class ActivityMemoryView: ActivitySectionView {

    private static let barHeight: CGFloat = 9
    private static let barRow: CGFloat = 15
    private static let legendRow: CGFloat = 15
    private static let swapRow: CGFloat = 15

    private var memory: MemoryActivity?
    /// Sticky: once this Mac has swapped, the line stays for the session.
    private var everSwapped = false

    init() { super.init(title: "MEMORY") }

    override var hasContent: Bool { (memory?.total ?? 0) > 0 }

    override var bodyHeight: CGFloat {
        Self.barRow + Self.legendRow + (everSwapped ? Self.swapRow : 0)
    }

    override var titleValue: String? {
        memory.map { "\(ActivityFormat.bytes($0.used)) of \(ActivityFormat.bytes($0.total))" }
    }

    override var spokenValue: String { memory.map(ActivitySpeech.memory) ?? "" }

    override func take(_ sample: ActivitySample) {
        guard let memory = sample.memory, memory.total > 0 else { return }
        self.memory = memory
        if memory.swapUsed > 0 { everSwapped = true }
    }

    override func forget() {
        memory = nil
        everSwapped = false
    }

    override func drawBody(in rect: CGRect) {
        guard let memory else { return }

        let bar = CGRect(x: rect.minX, y: rect.minY + (Self.barRow - Self.barHeight) / 2,
                         width: rect.width, height: Self.barHeight)
        let parts = [Double(memory.app), Double(memory.wired), Double(memory.compressed)]
        let widths = ActivityLayout.segments(parts, of: Double(memory.total),
                                             width: bar.width, minimumVisible: 2)
        ActivityDraw.segmented(bar, widths: widths, colors: ActivityTheme.memoryRamp,
                               radius: Self.barHeight / 2, track: ActivityTheme.track)

        drawLegend(memory, in: CGRect(x: rect.minX, y: rect.minY + Self.barRow,
                                      width: rect.width, height: Self.legendRow))

        guard everSwapped else { return }
        let swap = memory.swapUsed > 0
            ? "Swap \(ActivityFormat.bytes(memory.swapUsed)) of \(ActivityFormat.bytes(memory.swapTotal))"
            : "Swap idle"
        ActivityDraw.text(swap, font: ActivityTheme.smallValue, color: .tertiaryLabelColor,
                          in: CGRect(x: rect.minX, y: rect.minY + Self.barRow + Self.legendRow,
                                     width: rect.width, height: Self.swapRow))
    }

    private func drawLegend(_ memory: MemoryActivity, in rect: CGRect) {
        let entries = [("App", memory.app), ("Wired", memory.wired), ("Compressed", memory.compressed)]
        let colors = ActivityTheme.memoryRamp
        let dot: CGFloat = 6
        let dotGap: CGFloat = 4
        let nameGap: CGFloat = 4

        // Equal thirds would give "Compressed 1.5 GB" the same width as
        // "App 12.1 GB" and truncate the one that needed the room.
        let names = entries.map { $0.0 }
        let values = entries.map { ActivityFormat.bytes($0.1) }
        let widths = zip(names, values).map { name, value in
            dot + dotGap + ActivityDraw.width(name, font: ActivityTheme.footnote)
                + nameGap + ActivityDraw.width(value, font: ActivityTheme.legendValue)
        }
        let spans = ActivityLayout.distribute(widths, in: rect.width, minimumGap: 6)

        for (index, span) in spans.enumerated() {
            let x = rect.minX + span.origin
            ActivityDraw.bar(CGRect(x: x, y: rect.midY - dot / 2, width: dot, height: dot),
                             radius: dot / 2, color: colors[min(index, colors.count - 1)])

            let nameWidth = ActivityDraw.width(names[index], font: ActivityTheme.footnote)
            let nameX = x + dot + dotGap
            ActivityDraw.text(names[index], font: ActivityTheme.footnote, color: .tertiaryLabelColor,
                              in: CGRect(x: nameX, y: rect.minY,
                                         width: nameWidth, height: rect.height))
            let valueX = nameX + nameWidth + nameGap
            ActivityDraw.text(values[index], font: ActivityTheme.legendValue,
                              color: .secondaryLabelColor,
                              in: CGRect(x: valueX, y: rect.minY,
                                         width: max(0, x + span.length - valueX),
                                         height: rect.height))
        }
    }
}
