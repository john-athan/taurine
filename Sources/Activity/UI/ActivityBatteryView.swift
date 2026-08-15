import Cocoa

/// The tank. 🔋
///
/// One bar for how full the cell is, and one row underneath saying which way
/// the energy is moving and how fast. It sits directly under the power tile
/// because the two answer the same question from opposite ends: that tile is
/// what the chip is spending, this one is what the plug is supplying and what
/// the cell is banking, and on a charging laptop the second number is the
/// larger of the two by some distance.
///
/// The adapter belongs on the title row rather than in the body, next to the
/// percentage, in the same voice the power tile uses for "package   peak
/// 14.2 W". Two numbers there ("adapter 27.9 W of 30 W") say what is coming in
/// and what could come in, which is the pair that explains a slow charge: a Mac
/// pulling 27.9 of a possible 30 is charging as fast as that adapter allows,
/// and one pulling 27.9 of a possible 96 is not.
///
/// The bar is grey, not red. The accent in this panel means "look here" and it
/// is spent on the watts above and on a Mac that has got too hot; a battery at
/// 8% is worth knowing and is not worth taking the emphasis off the number the
/// panel exists for. The words in the row below carry the state instead.
///
/// The trap: the tile's height has to be the same on a plugged in Mac and an
/// unplugged one, or the panel changes height when somebody pulls the cable out
/// while it is open. Everything conditional therefore lives on a row that is
/// always drawn: the title row absorbs the adapter, and the entry row loses its
/// second half rather than its line.
final class ActivityBatteryView: ActivitySectionView {

    private static let barHeight: CGFloat = 9
    private static let barRow: CGFloat = 15
    private static let entryRow: CGFloat = 15

    /// Below this the flow is a rounding artefact rather than a current: a Mac
    /// held at its charge limit trickles a few milliwatts back and forth, and
    /// "NOT CHARGING 0.01 W" is a worse sentence than "NOT CHARGING".
    private static let quietWatts: Double = 0.05

    private var battery: BatteryActivity?

    init() { super.init(title: "BATTERY") }

    override var hasContent: Bool { battery != nil }
    override var bodyHeight: CGFloat { Self.barRow + Self.entryRow }

    override var titleValue: String? {
        guard let battery else { return nil }
        let charge = ActivityFormat.percent(battery.charge)
        guard let adapter = adapterNote(battery) else { return charge }
        return "\(charge)   \(adapter)"
    }

    override var spokenValue: String { battery.map(ActivitySpeech.battery) ?? "" }

    override func take(_ sample: ActivitySample) {
        guard let battery = sample.battery, battery.charge.isFinite else { return }
        self.battery = battery
    }

    override func forget() { battery = nil }

    // MARK: - the words

    /// What the adapter is giving, and what it could give. Nil on battery
    /// power, where there is no adapter to describe.
    private func adapterNote(_ battery: BatteryActivity) -> String? {
        guard battery.isPluggedIn else { return nil }
        switch (battery.inputWatts, battery.adapterWatts) {
        case let (input?, rating?):
            return "adapter \(ActivityFormat.watts(input)) of \(ActivityFormat.wattsRating(rating))"
        case let (input?, nil):
            return "adapter \(ActivityFormat.watts(input))"
        case let (nil, rating?):
            return "\(ActivityFormat.wattsRating(rating)) adapter"
        case (nil, nil):
            return nil
        }
    }

    /// The row under the bar: what is happening, and how long it has left.
    ///
    /// A value of nil is a label with nothing after it, which is what "CHARGED"
    /// and "NOT CHARGING" are: states, not quantities.
    private func entries(_ battery: BatteryActivity) -> [(label: String, value: String?)] {
        let flow = battery.batteryWatts.map { abs($0) }
        let rate = (flow ?? 0) >= Self.quietWatts ? flow.map { ActivityFormat.watts($0) } : nil

        var out: [(label: String, value: String?)]
        switch battery.state {
        case .charging:    out = [("CHARGING", rate)]
        case .discharging: out = [("ON BATTERY", rate)]
        case .charged:     out = [("CHARGED", nil)]
        case .held:        out = [("NOT CHARGING", nil)]
        }

        if let full = battery.timeToFull {
            out.append(("FULL IN", ActivityFormat.duration(full)))
        } else if let empty = battery.timeToEmpty {
            out.append(("LEFT", ActivityFormat.duration(empty)))
        }
        return out
    }

    // MARK: - drawing

    override func drawBody(in rect: CGRect) {
        guard let battery else { return }

        let bar = CGRect(x: rect.minX, y: rect.minY + (Self.barRow - Self.barHeight) / 2,
                         width: rect.width, height: Self.barHeight)
        ActivityDraw.meter(bar, fraction: battery.charge, radius: Self.barHeight / 2,
                           fill: ActivityTheme.meter, track: ActivityTheme.track)

        drawEntries(entries(battery), in: CGRect(x: rect.minX, y: rect.minY + Self.barRow,
                                                 width: rect.width, height: Self.entryRow))
    }

    /// The same shape as the power tile's parts row: a small-caps label, a gap,
    /// a value, and the slack spread between the pairs rather than inside them.
    private func drawEntries(_ entries: [(label: String, value: String?)], in rect: CGRect) {
        guard !entries.isEmpty else { return }

        let gap: CGFloat = 6
        let labels = entries.map { ActivityDraw.width($0.label, font: ActivityTheme.title,
                                                      kern: ActivityTheme.titleKern) }
        let values = entries.map { entry in
            entry.value.map { ActivityDraw.width($0, font: ActivityTheme.value) } ?? 0
        }
        let widths = zip(labels, values).map { label, value in
            value > 0 ? label + gap + value : label
        }
        let spans = ActivityLayout.distribute(widths, in: rect.width, minimumGap: 10)

        for (index, entry) in entries.enumerated() {
            let x = rect.minX + spans[index].origin
            ActivityDraw.text(entry.label, font: ActivityTheme.title, color: ActivityTheme.chrome,
                              in: CGRect(x: x, y: rect.minY,
                                         width: labels[index], height: rect.height),
                              kern: ActivityTheme.titleKern)
            guard let value = entry.value else { continue }
            let valueX = x + labels[index] + gap
            ActivityDraw.text(value, font: ActivityTheme.value, color: .labelColor,
                              in: CGRect(x: valueX, y: rect.minY,
                                         width: max(0, x + spans[index].length - valueX),
                                         height: rect.height))
        }
    }
}
