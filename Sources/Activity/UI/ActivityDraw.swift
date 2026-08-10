import Cocoa

/// The pen. ✒️
///
/// The handful of marks the panel is made of: a piece of text, a rounded bar, a
/// meter, a sparkline, a pill. Six section views draw the same five shapes, and
/// putting them here is what stops a bar in the memory tile from having a
/// slightly different corner radius than a bar in the processor tile, which is
/// the sort of thing nobody can name but everybody can see.
///
/// Everything takes a rect and returns nothing. There is no state, no cached
/// path and no layer: the whole panel repaints once a second, which at this
/// size costs less than the machinery to avoid it would.
///
/// The trap: these are written for flipped views, matching `ActivityLayout`,
/// and `text` in particular centres vertically inside the rect it is given
/// rather than sitting on a baseline. That is deliberate. Rows here are defined
/// by their box, not by their baseline, so a row keeps its height when the font
/// changes size for accessibility, and two strings of different sizes in one
/// row line up through their middles instead of drifting apart.
enum ActivityDraw {

    // MARK: - text

    @discardableResult
    static func text(_ string: String, font: NSFont, color: NSColor,
                     in rect: CGRect, align: NSTextAlignment = .left,
                     kern: CGFloat = 0, lines: Int = 1) -> CGSize {
        guard !string.isEmpty, rect.width > 0 else { return .zero }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        if kern != 0 { attributes[.kern] = kern }

        let attributed = NSAttributedString(string: string, attributes: attributes)
        let size = attributed.boundingRect(
            with: CGSize(width: rect.width, height: lines == 1 ? .greatestFiniteMagnitude
                                                               : CGFloat(lines) * font.boundingRectForFont.height),
            options: lines == 1 ? [] : [.usesLineFragmentOrigin])

        let y = rect.minY + (rect.height - size.height) / 2
        attributed.draw(with: CGRect(x: rect.minX, y: y, width: rect.width, height: size.height),
                        options: [.usesLineFragmentOrigin])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// How wide a string wants to be, for laying a row out around it.
    static func width(_ string: String, font: NSFont, kern: CGFloat = 0) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if kern != 0 { attributes[.kern] = kern }
        return ceil(NSAttributedString(string: string, attributes: attributes).size().width)
    }

    /// How tall a string wraps to inside a given width.
    static func height(_ string: String, font: NSFont, width: CGFloat, lines: Int) -> CGFloat {
        guard !string.isEmpty, width > 0 else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: string,
                                            attributes: [.font: font, .paragraphStyle: paragraph])
        let cap = CGFloat(lines) * ceil(font.boundingRectForFont.height)
        let box = attributed.boundingRect(with: CGSize(width: width, height: cap),
                                          options: [.usesLineFragmentOrigin])
        return min(cap, ceil(box.height))
    }

    // MARK: - bars

    static func bar(_ rect: CGRect, radius: CGFloat, color: NSColor) {
        guard rect.width > 0, rect.height > 0 else { return }
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: min(radius, rect.width / 2),
                     yRadius: min(radius, rect.height / 2)).fill()
    }

    /// A horizontal meter: a track with a fraction of it filled from the left.
    ///
    /// A non-zero fraction always draws at least `minimumFill` points, so a
    /// GPU at 1% is a visible sliver rather than a bar that looks switched off.
    static func meter(_ rect: CGRect, fraction: Double, radius: CGFloat,
                      fill: NSColor, track: NSColor, minimumFill: CGFloat = 3) {
        bar(rect, radius: radius, color: track)
        let clamped = fraction.isFinite ? min(1, max(0, fraction)) : 0
        guard clamped > 0 else { return }
        let width = max(minimumFill, rect.width * CGFloat(clamped))
        bar(CGRect(x: rect.minX, y: rect.minY, width: min(width, rect.width), height: rect.height),
            radius: radius, color: fill)
    }

    /// A vertical micro-bar, filling upward from the bottom of `rect`.
    /// One of these per core, which is what makes a cluster row legible at a
    /// glance: the shape of the comb is the shape of the load.
    ///
    /// The fill is a plain rectangle clipped to the track's rounded outline
    /// rather than a rounded rectangle of its own. Drawn as its own rounded
    /// shape, a core at 15% is a little pill floating at the bottom of a box,
    /// which reads as a dot rather than as a level; clipped, it has a flat top
    /// edge and inherits only the bottom corners, which is what a level looks
    /// like.
    static func core(_ rect: CGRect, busy: Double, radius: CGFloat,
                     fill: NSColor, track: NSColor, minimumFill: CGFloat = 2) {
        bar(rect, radius: radius, color: track)
        let clamped = busy.isFinite ? min(1, max(0, busy)) : 0
        guard clamped > 0, rect.width > 0, rect.height > 0 else { return }
        let height = min(rect.height, max(minimumFill, rect.height * CGFloat(clamped)))

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).setClip()
        fill.setFill()
        // Flipped view: growing upward means moving the origin down the rect.
        CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A stack of segments sharing one rounded track, clipped so the outer
    /// corners stay round no matter where the segment boundaries fall.
    static func segmented(_ rect: CGRect, widths: [CGFloat], colors: [NSColor],
                          radius: CGFloat, track: NSColor) {
        bar(rect, radius: radius, color: track)
        guard rect.width > 0, rect.height > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).setClip()
        var x = rect.minX
        for (index, width) in widths.enumerated() where width > 0 {
            colors[min(index, colors.count - 1)].setFill()
            CGRect(x: x, y: rect.minY, width: width, height: rect.height).fill()
            x += width
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - sparklines

    /// A line with the area under it filled, plus a dot on the newest value.
    ///
    /// The dot matters more than it looks: without it a flat line at the bottom
    /// of the rect is indistinguishable from an empty graph, and "no traffic"
    /// and "no data" are very different claims.
    static func sparkline(_ points: [CGPoint], in rect: CGRect, stroke: NSColor,
                          fillAlpha: CGFloat, lineWidth: CGFloat, dot: Bool) {
        guard let last = points.last, rect.height > 0 else { return }

        if points.count > 1 {
            let area = NSBezierPath()
            area.move(to: CGPoint(x: points[0].x, y: rect.maxY))
            for point in points { area.line(to: point) }
            area.line(to: CGPoint(x: last.x, y: rect.maxY))
            area.close()
            stroke.withAlphaComponent(fillAlpha).setFill()
            area.fill()

            let line = NSBezierPath()
            line.move(to: points[0])
            for point in points.dropFirst() { line.line(to: point) }
            line.lineWidth = lineWidth
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            stroke.setStroke()
            line.stroke()
        }

        guard dot else { return }
        let r = lineWidth + 0.6
        stroke.setFill()
        NSBezierPath(ovalIn: CGRect(x: last.x - r, y: last.y - r, width: r * 2, height: r * 2)).fill()
    }

    // MARK: - pills

    /// A rounded chip of text, used for the thermal state. Returns its width so
    /// the caller can right-align it without measuring the string twice.
    @discardableResult
    static func pill(_ string: String, font: NSFont, text: NSColor, background: NSColor,
                     rightEdge: CGFloat, centerY: CGFloat, height: CGFloat) -> CGFloat {
        let padding: CGFloat = 6
        let width = ActivityDraw.width(string, font: font, kern: 0.4) + padding * 2
        let rect = CGRect(x: rightEdge - width, y: centerY - height / 2, width: width, height: height)
        bar(rect, radius: height / 2, color: background)
        ActivityDraw.text(string, font: font, color: text, in: rect, align: .center, kern: 0.4)
        return width
    }
}
