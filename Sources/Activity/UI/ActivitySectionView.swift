import Cocoa

/// The tile. 🧱
///
/// What every section of the panel has in common: a small-caps title with an
/// optional value on the right, a body drawn underneath it, a height it asks
/// for, and a sentence for VoiceOver. Subclasses answer four questions and
/// never touch the title row or the accessibility plumbing.
///
/// The height question is the load-bearing one. A section that has never had
/// anything to say returns zero and the panel stacks straight over it, which is
/// how "a nil section is omitted, not drawn as zero" is actually implemented.
///
/// The trap, and the reason `remember` exists: sections must not flicker. The
/// first sample of a session carries `interval == 0`, so every rate probe
/// reports nothing, and disk and network are legitimately absent for exactly
/// one frame. If the panel laid itself out from the current sample alone it
/// would jump a hundred points taller one second after opening. So a section
/// holds the last value it was given and keeps drawing it: once a tile has
/// appeared it stays, and a probe that goes quiet mid-session shows its last
/// reading rather than vanishing. Values here are at most one second old, and
/// that is a better lie than a panel that rearranges itself while being read.
class ActivitySectionView: NSView {

    /// Small-caps title. Empty for the header, which is not a titled section.
    let title: String

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Taurine builds no nibs") }

    override var isFlipped: Bool { true }

    // MARK: - what subclasses answer

    /// Whether this section has ever been handed something to show.
    var hasContent: Bool { false }

    /// Height of the part below the title row.
    var bodyHeight: CGFloat { 0 }

    /// Optional right-hand value on the title row.
    var titleValue: String? { nil }

    /// The VoiceOver sentence for this tile.
    var spokenValue: String { "" }

    func drawBody(in rect: CGRect) {}

    /// Take one sample. Subclasses keep whatever they need and ignore the rest.
    func take(_ sample: ActivitySample) {}

    /// Drop the session. Called when the panel closes.
    func forget() {}

    // MARK: - geometry

    /// What the panel should reserve for this tile, or zero to skip it.
    final var contentHeight: CGFloat {
        guard hasContent else { return 0 }
        return (title.isEmpty ? 0 : ActivityTheme.titleHeight) + bodyHeight
    }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        guard hasContent else { return }
        var body = bounds

        if !title.isEmpty {
            let row = CGRect(x: 0, y: 0, width: bounds.width, height: ActivityTheme.titleHeight)
            ActivityDraw.text(title, font: ActivityTheme.title, color: .secondaryLabelColor,
                              in: row, align: .left, kern: ActivityTheme.titleKern)
            if let value = titleValue {
                ActivityDraw.text(value, font: ActivityTheme.smallValue,
                                  color: ActivityTheme.quietData, in: row, align: .right)
            }
            body = CGRect(x: 0, y: row.maxY, width: bounds.width, height: bounds.height - row.height)
        }

        guard body.height > 0 else { return }
        drawBody(in: body)
    }

    // MARK: - accessibility

    // Hand-drawn views expose nothing to VoiceOver on their own: without these
    // the panel is one unlabelled group and the reader gets silence.
    override func isAccessibilityElement() -> Bool { hasContent }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? {
        title.isEmpty ? nil : ActivitySpeech.tileName(title)
    }
    override func accessibilityValue() -> Any? { spokenValue }
}
