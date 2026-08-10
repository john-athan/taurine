import Cocoa

/// The nameplate. 🏷️
///
/// Which Mac this is, and whether it is currently too hot to be itself. Two
/// facts, one line, no chrome.
///
/// The chip name comes from `machdep.cpu.brand_string` and is read once: a
/// process does not change chips. It is also the one string in the panel that
/// is not a number, which is why it gets to be the largest text that is not the
/// power headline.
///
/// The thermal chip appears only when the state is something other than
/// nominal. That is the whole design of it: a badge that is always on the
/// screen saying "NOMINAL" trains people to stop reading badges, and the one
/// time it says "SERIOUS" they will not notice. Fair is drawn in the quiet
/// greys; serious and critical get the accent, because by then the numbers
/// below are being throttled and the reader deserves to know why.
///
/// The trap: `ProcessInfo.thermalState` is the only heat signal here, and it
/// is deliberately not a temperature. The SMC keys that would give degrees are
/// undocumented and move between chip generations, and a confidently wrong
/// temperature is worse than no temperature at all.
final class ActivityHeaderView: ActivitySectionView {

    /// Read once, for the life of the process.
    static let chipName: String = {
        let raw = CPUTopology.sysctlString("machdep.cpu.brand_string")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return "This Mac" }
        return raw
    }()

    private var thermal: ProcessInfo.ThermalState?

    init() { super.init(title: "") }

    override var hasContent: Bool { true }
    override var bodyHeight: CGFloat { 24 }

    override func take(_ sample: ActivitySample) {
        // Sticky, like every other section: a thermal probe that stops
        // answering must not make the badge blink out of existence.
        if let state = sample.thermal?.state { thermal = state }
    }

    override func forget() { thermal = nil }

    override var spokenValue: String {
        guard let thermal, let heat = ActivitySpeech.thermal(thermal) else {
            return "\(Self.chipName)."
        }
        return "\(Self.chipName), \(heat)."
    }

    override func accessibilityLabel() -> String? { "Machine" }

    override func drawBody(in rect: CGRect) {
        var nameWidth = rect.width

        if let thermal, let badge = Self.badge(for: thermal) {
            let accented = thermal == .serious || thermal == .critical
            let foreground = accented ? ActivityTheme.accent : NSColor.secondaryLabelColor
            let background = accented
                ? ActivityTheme.accent.withAlphaComponent(0.16)
                : ActivityTheme.chipBackground
            let width = ActivityDraw.pill(badge, font: ActivityTheme.chipBadge,
                                          text: foreground, background: background,
                                          rightEdge: rect.maxX, centerY: rect.midY, height: 16)
            nameWidth -= width + 10
        }

        ActivityDraw.text(Self.chipName, font: ActivityTheme.chipName, color: .labelColor,
                          in: CGRect(x: rect.minX, y: rect.minY,
                                     width: max(0, nameWidth), height: rect.height))
    }

    /// Nil when the machine is nominal, which is the state worth no pixels.
    private static func badge(for state: ProcessInfo.ThermalState) -> String? {
        switch state {
        case .nominal:  return nil
        case .fair:     return "FAIR"
        case .serious:  return "THROTTLING"
        case .critical: return "CRITICAL"
        @unknown default: return nil
        }
    }
}
