import Cocoa

/// The panel. 📊
///
/// The whole readout: a nameplate, six tiles and a footer, stacked down one
/// sixteen-point margin. It owns the tiles, hands each of them every sample and
/// lets each decide whether it has anything to say, then stacks whatever is
/// left. A Mac with no energy counters simply has no power tile and a shorter
/// panel, with no gap where one would have been.
///
/// The order is deliberate and is a small argument: load first (processor,
/// graphics), then what that load costs (power, and the battery paying for it),
/// then what it is using (memory), then what it is moving (disk, network). The
/// battery follows the watts rather than opening the panel because it is the
/// same subject read from the other end, and because a laptop's charge is a
/// number macOS already puts in the menu bar. Power sits in the middle
/// rather than at the top because it reads as the consequence of the two tiles
/// above it, and because thirty points of red a third of the way down a calm
/// grey panel is unmissable wherever it is.
///
/// Under all of it, two notes in small print: what this Mac could not answer,
/// and what the panel costs while it is open. Both are claims Taurine makes
/// about itself, so both belong at the bottom of the thing making them rather
/// than in a document nobody reads.
///
/// The trap: this view never resizes itself. `preferredHeight` is what the
/// popover should be, and the controller sets it. Because every probe takes its
/// baseline when it opens, the first sample already carries rates, so the set of
/// tiles is settled on the first frame and the height never changes again
/// within a session. Tiles are sticky as well, which means a probe that starts
/// failing part way through keeps its last value rather than collapsing the
/// panel around the gap. A view that resized its own window on every sample
/// would be a panel that twitched for as long as it was open.
final class ActivityPanelView: NSView {

    private let header = ActivityHeaderView()
    private let cpu = ActivityCPUView()
    private let gpu = ActivityGPUView()
    private let power = ActivityPowerView()
    private let battery = ActivityBatteryView()
    private let memory = ActivityMemoryView()
    private let disk = ActivityTrafficView.disk()
    private let network = ActivityTrafficView.network()

    /// The two footer lines. Text fields rather than hand-drawn marks because
    /// they are the only prose on the panel, and a field measures the string it
    /// is about to draw: whatever it reserves is what it takes, however many
    /// lines that turns out to be. Everything above them is a single line and
    /// is measured by the pen instead.
    let notice = NSTextField(labelWithString: "")
    let receipt = NSTextField(labelWithString: "")

    /// Air between the two footer lines. Less than a section gap, because they
    /// are one block of small print rather than two sections.
    private static let footerGap: CGFloat = 5

    private var sections: [ActivitySectionView] {
        [header, cpu, gpu, power, battery, memory, disk, network]
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: ActivityTheme.width, height: 200))

        // Tiles first, then the footer, so VoiceOver arrows through the panel
        // in the order it is drawn.
        for section in sections { addSubview(section) }
        configure(notice, font: ActivityTheme.footnote)
        configure(receipt, font: ActivityTheme.receipt)
        receipt.toolTip = Self.receiptExplanation
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Taurine builds no nibs") }

    /// Both footer lines wrap; neither truncates. `NSTextField(labelWithString:)`
    /// hands back a cell that does not wrap at all, whatever
    /// `maximumNumberOfLines` is set to afterwards: it draws one line and ends
    /// it with an ellipsis. On a Mac where five probes decline, that ellipsis
    /// eats the list of names, which is the only thing the sentence exists to
    /// deliver. Turning single-line mode off and the cell's own wrapping on is
    /// what makes the field lay out, and measure, as many lines as it needs.
    private func configure(_ field: NSTextField, font: NSFont) {
        field.font = font
        field.textColor = ActivityTheme.quietData
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.isSelectable = false
        addSubview(field)
    }

    // MARK: - the sample

    func update(_ sample: ActivitySample) {
        for section in sections { section.take(sample) }

        notice.stringValue = ActivitySpeech.unavailable(sample.unavailable.map(\.name)) ?? ""
        notice.toolTip = sample.unavailable.isEmpty ? nil
            : sample.unavailable.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
        receipt.stringValue = Self.receiptLine

        relayout()
        needsDisplay = true
    }

    /// Throw the session away. Nothing survives the panel closing: not the
    /// minute of history, not the last values, not the list of what was
    /// missing, and not the receipt, which is only true while the timer it
    /// counts is running.
    func forget() {
        for section in sections { section.forget() }
        notice.stringValue = ""
        notice.toolTip = nil
        receipt.stringValue = ""
        relayout()
        needsDisplay = true
    }

    // MARK: - the receipt

    /// What this panel costs while it is on screen, in the voice of the menu's
    /// own `45.2 MB · 0 timers · 0 sockets` badge.
    ///
    /// The timer count is written down rather than read back, and it is right
    /// for a reason worth stating: a sample only ever arrives from the
    /// monitor's timer, that timer is created when the panel opens and
    /// cancelled when it closes, and the panel creates no other. So while there
    /// is a sample to draw there is exactly one of them, and when there is not,
    /// this line is not drawn at all. The cadence is the one in
    /// `ActivityPanelController.interval`, which is a second.
    ///
    /// The megabytes are Taurine's whole resident footprint, read live from the
    /// kernel by `Diagnostics` rather than asserted, and they are labelled with
    /// the app's name rather than the panel's: the panel's own share of them is
    /// not separable, and naming a number that cannot be measured is the one
    /// thing this panel refuses to do.
    private static var receiptLine: String {
        String(format: "This panel: 1 timer · 1 sample a second · Taurine %.1f MB",
               Diagnostics.residentMemoryMB)
    }

    private static let receiptExplanation =
        "One repeating timer, this panel's sampler, at one sample a second. It is cancelled "
        + "and every probe is closed the moment the panel closes, so nothing here runs while "
        + "it is shut. The megabytes are Taurine's resident memory, read from the kernel with "
        + "task_info, not the panel's share of it."

    // MARK: - geometry

    /// What the popover should be, for the sample currently held.
    private(set) var preferredHeight: CGFloat = 200

    /// What a footer line needs at the panel's width, asked of the cell that
    /// will draw it. Anything measured any other way is a second opinion, and
    /// the two lines reserved for a sentence that rendered as one were exactly
    /// that.
    private func height(of field: NSTextField) -> CGFloat {
        guard !field.stringValue.isEmpty, let cell = field.cell else { return 0 }
        let unbounded = CGRect(x: 0, y: 0, width: ActivityTheme.content,
                               height: .greatestFiniteMagnitude)
        return ceil(cell.cellSize(forBounds: unbounded).height)
    }

    private var footerHeight: CGFloat {
        let top = height(of: notice)
        let bottom = height(of: receipt)
        guard top > 0, bottom > 0 else { return top + bottom }
        return top + Self.footerGap + bottom
    }

    private func relayout() {
        let heights = sections.map(\.contentHeight) + [footerHeight]
        let origins = ActivityLayout.stack(heights, spacing: ActivityTheme.sectionGap,
                                           top: ActivityTheme.margin)

        for (index, section) in sections.enumerated() {
            section.frame = CGRect(x: ActivityTheme.margin, y: origins[index],
                                   width: ActivityTheme.content, height: heights[index])
            section.isHidden = heights[index] <= 0
            section.needsDisplay = true
        }

        var y = origins[origins.count - 1]
        for field in [notice, receipt] {
            let line = height(of: field)
            field.frame = CGRect(x: ActivityTheme.margin, y: y,
                                 width: ActivityTheme.content, height: line)
            field.isHidden = line <= 0
            guard line > 0 else { continue }
            y += line + Self.footerGap
        }

        preferredHeight = ActivityLayout.stackHeight(heights, spacing: ActivityTheme.sectionGap,
                                                     top: ActivityTheme.margin,
                                                     bottom: ActivityTheme.margin)
        frame = CGRect(x: 0, y: 0, width: ActivityTheme.width, height: preferredHeight)
    }

    // MARK: - accessibility

    // The panel is a group whose children are the tiles. Each tile answers with
    // one finished sentence, so arrowing down the panel reads it aloud in the
    // order it is drawn instead of announcing an empty group.
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Activity" }
}
