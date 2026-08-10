import Cocoa

/// The palette. 🎨
///
/// Every colour, font and measurement the panel uses, in one place, so that a
/// row added later lands on the same grid as the rows above it without anybody
/// having to remember what the grid was.
///
/// Three rules are encoded here rather than written down:
///
///   • **One accent.** Taurine's red belongs to the power headline and to a
///     Mac that has got too hot. Everything else is greys drawn from the system
///     label colours. A panel where six things are coloured is a panel where
///     nothing is emphasised, and the number people open this for is the watts.
///
///   • **Semantic colours only.** `labelColor` and its quieter siblings already
///     know what to do in light appearance, in dark appearance, in increased
///     contrast and behind a vibrant popover material. A hand-picked grey knows
///     none of that and looks wrong in exactly one of those four, which is
///     always the one nobody checked.
///
///   • **Monospaced digits everywhere a number changes.** Not monospaced text:
///     `monospacedDigitSystemFont` keeps the letters proportional and pins the
///     digits to one width, so "8.1 W" becoming "14.2 W" moves nothing except
///     the digits themselves.
///
/// The trap: the accent has to be two different reds. The one that reads
/// correctly on a dark popover is washed out and stringy on a light one, and
/// the one that reads correctly on light is muddy on dark. It is therefore a
/// dynamic colour built from a provider, and it must be *drawn* inside
/// `draw(_:)` where AppKit has made the view's appearance current. Resolving it
/// early, at init or into a `CGColor` held in a property, freezes whichever
/// appearance happened to be active first and the panel then stops responding
/// to the system switching.
enum ActivityTheme {

    // MARK: - the grid

    /// A menu bar popover wants to be narrow enough to read in one fixation.
    static let width: CGFloat = 320
    static let margin: CGFloat = 16
    static var content: CGFloat { width - margin * 2 }

    /// Air between sections. Generous, because the sections are dense.
    static let sectionGap: CGFloat = 17
    /// The small-caps title above each section.
    static let titleHeight: CGFloat = 15
    /// One cluster, one meter, one direction of traffic.
    static let rowHeight: CGFloat = 19

    /// Past this the panel scrolls rather than growing off the screen. A Mac
    /// Studio Ultra has six clusters and a footer; a hypothetical chip with
    /// twenty would otherwise produce a popover taller than the display.
    static let maximumHeight: CGFloat = 620

    // MARK: - colours

    /// Taurine's red, which is the bull's red, at two different weights so it
    /// carries on both appearances.
    static let accent = NSColor(name: "TaurineActivityAccent") { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 1.00, green: 0.38, blue: 0.38, alpha: 1)
            : NSColor(calibratedRed: 0.82, green: 0.14, blue: 0.14, alpha: 1)
    }

    /// The empty part of any meter.
    static var track: NSColor { .quaternaryLabelColor }
    /// The full part of any meter that is not the accent.
    static var meter: NSColor { .secondaryLabelColor }

    /// The core comb needs more separation than a wide meter does. A bar eight
    /// points across reads as one solid block unless its empty part is clearly
    /// fainter than its full part, and `quaternary` against `secondary` is not
    /// enough contrast at that size even though it is plenty at meter size.
    ///
    /// Both are derived from `labelColor`, which is opaque. That matters:
    /// `withAlphaComponent` *replaces* a colour's alpha rather than scaling it,
    /// so asking `quaternaryLabelColor` (already 10% opaque) for 55% makes it
    /// five times brighter, not half as bright. Deriving translucency only from
    /// opaque colours is the way not to trip over that.
    static var coreTrack: NSColor { NSColor.labelColor.withAlphaComponent(0.13) }
    static var coreFill: NSColor { NSColor.labelColor.withAlphaComponent(0.82) }

    /// The same trap, for the thermal chip's background.
    static var chipBackground: NSColor { NSColor.labelColor.withAlphaComponent(0.10) }

    /// Memory's three segments, as one monochrome ramp. Hue would be louder
    /// than the power headline and would fight it for attention.
    static var memoryRamp: [NSColor] {
        [NSColor.labelColor.withAlphaComponent(0.80),
         NSColor.labelColor.withAlphaComponent(0.48),
         NSColor.labelColor.withAlphaComponent(0.26)]
    }

    // MARK: - fonts

    /// Section titles: small, spaced, quiet. They label, they do not compete.
    static var title: NSFont { .systemFont(ofSize: 10, weight: .semibold) }
    static let titleKern: CGFloat = 0.6

    static var chipName: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    static var chipBadge: NSFont { .systemFont(ofSize: 9, weight: .semibold) }

    static var hero: NSFont { .monospacedDigitSystemFont(ofSize: 30, weight: .semibold) }
    static var heroUnit: NSFont { .systemFont(ofSize: 13, weight: .medium) }

    static var value: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .medium) }
    static var smallValue: NSFont { .monospacedDigitSystemFont(ofSize: 10, weight: .regular) }
    static var legendValue: NSFont { .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium) }

    static var rowLabel: NSFont { .systemFont(ofSize: 10, weight: .semibold) }
    static var caption: NSFont { .systemFont(ofSize: 10, weight: .regular) }
    static var footnote: NSFont { .systemFont(ofSize: 9.5, weight: .regular) }

    // MARK: - motion

    /// The system's reduce-motion switch, read at the moment it matters rather
    /// than cached: it can be flipped in System Settings while Taurine is
    /// running, and a cached answer would need an observer to stay honest.
    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

extension NSAppearance {
    /// Whether this appearance is one of the dark ones. `name` alone is not
    /// enough: vibrant and high-contrast variants have their own names, and
    /// `bestMatch` is the supported way to ask the question.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
