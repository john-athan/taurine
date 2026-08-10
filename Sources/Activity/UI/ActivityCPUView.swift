import Cocoa

/// The clusters. 🧮
///
/// One row per cluster: its name, a comb of per-core micro-bars, its busy
/// percentage and its clock. The comb is the point. A single averaged
/// percentage cannot tell you whether one core is pinned or six are half busy,
/// and on a chip whose whole design is heterogeneous cores that distinction is
/// most of what there is to see.
///
/// Rows are laid out from the right: the clock takes a fixed column, the
/// percentage takes another, and the comb gets whatever is left. That ordering
/// means the numbers stay in the same two columns on every row of every chip,
/// so they can be read down as a column rather than hunted for, and it is the
/// comb, the least precise element, that absorbs the variation in width.
///
/// The trap: every row's comb is divided into as many slots as the *largest*
/// cluster on the chip has cores, not as many as that row has. An M4 Pro has
/// four efficiency cores and five performance cores, and sizing each row to its
/// own count gives two slightly different bar widths stacked on top of each
/// other, which reads as a mistake even to somebody who cannot say what is
/// wrong. Shared slots also mean the same core position lands in the same
/// column on every row, so a comb can be read down as well as across. The short
/// row simply leaves its last slot empty.
final class ActivityCPUView: ActivitySectionView {

    private static let clockColumn: CGFloat = 62
    private static let percentColumn: CGFloat = 34
    private static let idColumn: CGFloat = 22
    private static let columnGap: CGFloat = 10
    private static let coreGap: CGFloat = 3
    private static let coreWidth: CGFloat = 8
    private static let coreHeight: CGFloat = 14

    private var cpu: CPUActivity?

    init() { super.init(title: "CPU") }

    override var hasContent: Bool { !(cpu?.clusters.isEmpty ?? true) }

    override var bodyHeight: CGFloat {
        CGFloat(cpu?.clusters.count ?? 0) * ActivityTheme.rowHeight
    }

    override var titleValue: String? {
        cpu.map { ActivityFormat.percent($0.busy) + " busy" }
    }

    override var spokenValue: String {
        cpu.map(ActivitySpeech.cpu) ?? ""
    }

    override func take(_ sample: ActivitySample) {
        if let cpu = sample.cpu, !cpu.clusters.isEmpty { self.cpu = cpu }
    }

    override func forget() { cpu = nil }

    override func drawBody(in rect: CGRect) {
        guard let cpu else { return }

        // An empty column is worse than a narrow panel: on a chip that reports
        // no clocks at all, the whole column goes away and the percentages move
        // out to the edge where the eye already is.
        let anyClock = cpu.clusters.contains { $0.frequencyMHz != nil }
        let clockWidth = anyClock ? Self.clockColumn : 0

        // Slots shared across every row, so the combs line up as a grid.
        let slots = cpu.clusters.map(\.cores.count).max() ?? 0
        let combLeft = rect.minX + Self.idColumn
        let combRight = rect.maxX - clockWidth - (anyClock ? Self.columnGap : 0)
            - Self.percentColumn - Self.columnGap
        let spans = ActivityLayout.bars(count: slots, width: max(0, combRight - combLeft),
                                        gap: Self.coreGap, minimum: 2, maximum: Self.coreWidth)

        for (index, cluster) in cpu.clusters.enumerated() {
            let row = CGRect(x: rect.minX, y: rect.minY + CGFloat(index) * ActivityTheme.rowHeight,
                             width: rect.width, height: ActivityTheme.rowHeight)
            draw(cluster, in: row, spans: spans, combLeft: combLeft, clockWidth: clockWidth)
        }
    }

    private func draw(_ cluster: CPUActivity.Cluster, in row: CGRect,
                      spans: [ActivityLayout.Span], combLeft: CGFloat, clockWidth: CGFloat) {
        ActivityDraw.text(cluster.id, font: ActivityTheme.rowLabel, color: .secondaryLabelColor,
                          in: CGRect(x: row.minX, y: row.minY,
                                     width: Self.idColumn, height: row.height))

        var percentRight = row.maxX
        if clockWidth > 0 {
            let clock = CGRect(x: row.maxX - clockWidth, y: row.minY,
                               width: clockWidth, height: row.height)
            if let mhz = cluster.frequencyMHz {
                ActivityDraw.text(ActivityFormat.megahertz(mhz), font: ActivityTheme.smallValue,
                                  color: .tertiaryLabelColor, in: clock, align: .right)
            }
            percentRight = clock.minX - Self.columnGap
        }

        ActivityDraw.text(ActivityFormat.percent(cluster.busy), font: ActivityTheme.value,
                          color: .labelColor,
                          in: CGRect(x: percentRight - Self.percentColumn, y: row.minY,
                                     width: Self.percentColumn, height: row.height),
                          align: .right)

        let top = row.midY - Self.coreHeight / 2
        let track = ActivityTheme.coreTrack
        let fill = ActivityTheme.coreFill

        for (span, busy) in zip(spans, cluster.cores) {
            ActivityDraw.core(CGRect(x: combLeft + span.origin, y: top,
                                     width: span.length, height: Self.coreHeight),
                              busy: busy, radius: min(2, span.length / 2),
                              fill: fill, track: track)
        }
    }
}
