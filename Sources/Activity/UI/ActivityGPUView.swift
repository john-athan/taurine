import Cocoa

/// The graphics core. 🎮
///
/// One number and one bar. The GPU has no clusters and no per-core visibility
/// worth the name, so pretending otherwise with a comb of fake cores would be
/// decoration standing in for information.
///
/// It is a separate tile rather than a fourth row of the processor tile because
/// its percentage means something different: a CPU cluster at 100% is four or
/// five cores saturated, and a GPU at 100% is a single scheduler saturated.
/// Stacking them in one list would invite reading them as comparable.
///
/// The trap: `utilization` and `frequencyMHz` come from different places and
/// fail independently. A Mac can know how busy its GPU is without knowing how
/// fast it is running, so the clock column exists only when there is a clock to
/// put in it, and the meter takes that width back rather than stopping short of
/// an empty column. There is no right edge to line up with: the memory bar
/// below is full width whatever the GPU knows about itself, so a meter that
/// held a fixed width would line up with nothing and read as a bar that failed
/// to finish drawing. Every tile shares its left edge, which is the alignment
/// the eye actually follows down a column this narrow.
final class ActivityGPUView: ActivitySectionView {

    private static let clockColumn: CGFloat = 62
    private static let columnGap: CGFloat = 10

    private var gpu: GPUActivity?

    init() { super.init(title: "GPU") }

    override var hasContent: Bool { gpu != nil }
    override var bodyHeight: CGFloat { ActivityTheme.rowHeight }

    override var titleValue: String? {
        gpu.map { ActivityFormat.percent($0.utilization) + " busy" }
    }

    override var spokenValue: String { gpu.map(ActivitySpeech.gpu) ?? "" }

    override func take(_ sample: ActivitySample) {
        if let gpu = sample.gpu { self.gpu = gpu }
    }

    override func forget() { gpu = nil }

    override func drawBody(in rect: CGRect) {
        guard let gpu else { return }

        // No clock, no column: the meter takes the space rather than leaving a
        // hole where a number would have been.
        var barRight = rect.maxX
        if let mhz = gpu.frequencyMHz {
            let clock = CGRect(x: rect.maxX - Self.clockColumn, y: rect.minY,
                               width: Self.clockColumn, height: rect.height)
            ActivityDraw.text(ActivityFormat.megahertz(mhz), font: ActivityTheme.smallValue,
                              color: ActivityTheme.quietData, in: clock, align: .right)
            barRight = clock.minX - Self.columnGap
        }

        let barHeight: CGFloat = 8
        let width = barRight - rect.minX
        guard width > 0 else { return }

        ActivityDraw.meter(CGRect(x: rect.minX, y: rect.midY - barHeight / 2,
                                  width: width, height: barHeight),
                           fraction: gpu.utilization, radius: barHeight / 2,
                           fill: ActivityTheme.meter, track: ActivityTheme.track)
    }
}
