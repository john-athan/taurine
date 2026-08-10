import Cocoa

/// The panel. 📊
///
/// The whole readout: a nameplate, five tiles and a footer, stacked down one
/// sixteen-point margin. It owns the tiles, hands each of them every sample and
/// lets each decide whether it has anything to say, then stacks whatever is
/// left. A Mac with no energy counters simply has no power tile and a shorter
/// panel, with no gap where one would have been.
///
/// The order is deliberate and is a small argument: load first (processor,
/// graphics), then what that load costs (power), then what it is using
/// (memory), then what it is moving (disk, network). Power sits in the middle
/// rather than at the top because it reads as the consequence of the two tiles
/// above it, and because thirty points of red a third of the way down a calm
/// grey panel is unmissable wherever it is.
///
/// The trap: this view never resizes itself. `preferredHeight` is what the
/// popover should be, and the controller sets it. The height genuinely changes
/// once per session, one second after opening, when the rate probes get their
/// first interval and the disk and network tiles appear; every tile is sticky
/// after that, so the second change never comes. A view that resized its own
/// window on every sample would be a panel that twitched for as long as it was
/// open.
final class ActivityPanelView: NSView {

    private let header = ActivityHeaderView()
    private let cpu = ActivityCPUView()
    private let gpu = ActivityGPUView()
    private let power = ActivityPowerView()
    private let memory = ActivityMemoryView()
    private let disk = ActivityTrafficView.disk()
    private let network = ActivityTrafficView.network()

    /// A real text field rather than another hand-drawn tile: the footer is the
    /// one place the panel has prose, and prose wants wrapping, selection and
    /// an accessibility label it gets for free.
    private let footer = NSTextField(labelWithString: "")

    private var sections: [ActivitySectionView] {
        [header, cpu, gpu, power, memory, disk, network]
    }

    /// Names of probes that declined to open, kept so the footer can say so.
    private var unavailable: [String] = []

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: ActivityTheme.width, height: 200))

        footer.font = ActivityTheme.footnote
        footer.textColor = .tertiaryLabelColor
        footer.maximumNumberOfLines = 2
        footer.lineBreakMode = .byTruncatingTail
        footer.isSelectable = false
        addSubview(footer)

        for section in sections { addSubview(section) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Taurine builds no nibs") }

    // MARK: - the sample

    func update(_ sample: ActivitySample) {
        for section in sections { section.take(sample) }

        unavailable = sample.unavailable.map(\.name)
        footer.stringValue = ActivitySpeech.unavailable(unavailable) ?? ""
        footer.toolTip = sample.unavailable.isEmpty ? nil
            : sample.unavailable.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")

        relayout()
        needsDisplay = true
    }

    /// Throw the session away. Nothing survives the panel closing: not the
    /// minute of history, not the last values, not the list of what was
    /// missing.
    func forget() {
        for section in sections { section.forget() }
        unavailable = []
        footer.stringValue = ""
        footer.toolTip = nil
        relayout()
        needsDisplay = true
    }

    // MARK: - geometry

    /// What the popover should be, for the sample currently held.
    private(set) var preferredHeight: CGFloat = 200

    private var footerHeight: CGFloat {
        guard !footer.stringValue.isEmpty else { return 0 }
        return ActivityDraw.height(footer.stringValue, font: ActivityTheme.footnote,
                                   width: ActivityTheme.content, lines: 2) + 4
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

        let footerY = origins[origins.count - 1]
        footer.frame = CGRect(x: ActivityTheme.margin, y: footerY,
                              width: ActivityTheme.content, height: heights[heights.count - 1])
        footer.isHidden = heights[heights.count - 1] <= 0

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
