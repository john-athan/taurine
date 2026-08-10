import Cocoa

/// The pipes. 🔀
///
/// Two rows of the same shape, used twice: disk read and write, network in and
/// out. One class rather than two, because the only difference between a disk
/// tile and a network tile is four words and a unit that is already the same.
///
/// Both rows of a tile share one vertical scale. That is the decision worth
/// stating: scaling each direction to its own peak makes a trickle of uploads
/// look exactly like a torrent of downloads, and the first thing anybody wants
/// from these two graphs is to compare them to each other. A shared axis costs
/// the quieter direction its detail and buys the pair their meaning.
///
/// The trap: a rate of zero must draw as a visible flat line on the floor and
/// not as nothing. "No traffic" and "no data" look identical if the empty case
/// paints nothing, and this panel refuses to let those two be confused, so
/// `ActivityDraw.sparkline` always puts a dot on the newest value even when the
/// line has nowhere to go.
final class ActivityTrafficView: ActivitySectionView {

    private static let directionColumn: CGFloat = 40
    private static let valueColumn: CGFloat = 82
    private static let columnGap: CGFloat = 12

    private let inboundName: String
    private let outboundName: String
    private let spokenInbound: String
    private let spokenOutbound: String

    private var traffic: TrafficRate?
    private var inbound = ActivityHistory()
    private var outbound = ActivityHistory()

    /// `read` handed the sample; the tile pulls its own slice out of it. That
    /// keeps the panel from having to know which tile wants which field.
    private let slice: (ActivitySample) -> TrafficRate?

    init(title: String, inbound: String, outbound: String,
         spokenInbound: String, spokenOutbound: String,
         slice: @escaping (ActivitySample) -> TrafficRate?) {
        self.inboundName = inbound
        self.outboundName = outbound
        self.spokenInbound = spokenInbound
        self.spokenOutbound = spokenOutbound
        self.slice = slice
        super.init(title: title)
    }

    static func disk() -> ActivityTrafficView {
        ActivityTrafficView(title: "DISK", inbound: "read", outbound: "write",
                            spokenInbound: "read", spokenOutbound: "written") { $0.disk }
    }

    static func network() -> ActivityTrafficView {
        ActivityTrafficView(title: "NETWORK", inbound: "in", outbound: "out",
                            spokenInbound: "received", spokenOutbound: "sent") { $0.network }
    }

    override var hasContent: Bool { traffic != nil }
    override var bodyHeight: CGFloat { ActivityTheme.rowHeight * 2 }

    override var spokenValue: String {
        traffic.map { ActivitySpeech.traffic($0, inbound: spokenInbound, outbound: spokenOutbound) } ?? ""
    }

    override func take(_ sample: ActivitySample) {
        guard let rate = slice(sample) else { return }
        traffic = rate
        inbound.append(rate.inboundBytesPerSecond)
        outbound.append(rate.outboundBytesPerSecond)
    }

    override func forget() {
        traffic = nil
        inbound.forget()
        outbound.forget()
    }

    override func drawBody(in rect: CGRect) {
        guard let traffic else { return }

        // One axis for both directions, so the two lines can be compared.
        let peak = max(inbound.maximum ?? 0, outbound.maximum ?? 0)
        let scale = ActivityLayout.niceCeiling(peak)

        draw(name: inboundName, rate: traffic.inboundBytesPerSecond, history: inbound, scale: scale,
             in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: ActivityTheme.rowHeight))
        draw(name: outboundName, rate: traffic.outboundBytesPerSecond, history: outbound, scale: scale,
             in: CGRect(x: rect.minX, y: rect.minY + ActivityTheme.rowHeight,
                        width: rect.width, height: ActivityTheme.rowHeight))
    }

    private func draw(name: String, rate: Double, history: ActivityHistory,
                      scale: Double, in row: CGRect) {
        ActivityDraw.text(name, font: ActivityTheme.caption, color: .tertiaryLabelColor,
                          in: CGRect(x: row.minX, y: row.minY,
                                     width: Self.directionColumn, height: row.height))

        let value = CGRect(x: row.minX + Self.directionColumn, y: row.minY,
                           width: Self.valueColumn, height: row.height)
        // An idle pipe is quiet typography as well as a flat line.
        ActivityDraw.text(ActivityFormat.bytesPerSecond(rate), font: ActivityTheme.value,
                          color: rate > 0 ? .labelColor : .tertiaryLabelColor,
                          in: value, align: .right)

        let left = value.maxX + Self.columnGap
        let graph = CGRect(x: left, y: row.minY + 3, width: row.maxX - left, height: row.height - 6)
        guard graph.width > 20 else { return }

        let points = ActivityLayout.sparkline(history.ordered, capacity: history.capacity,
                                              in: graph, scale: scale)
        ActivityDraw.sparkline(points, in: graph, stroke: ActivityTheme.meter,
                               fillAlpha: 0.12, lineWidth: 1.1, dot: true)
    }
}
