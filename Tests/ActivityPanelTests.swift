import Cocoa

/// The panel's own arithmetic, and the lifecycle ADR 0002 rests on.
///
/// Two things are checked here that cannot be checked by looking at the screen.
/// The first is the footer: what it reserves has to be what it draws, and the
/// bug that made this file necessary reserved two lines for a sentence that
/// rendered as one and lost the names it existed to list. The second is the
/// shutter. "Every route out closes every probe" is the claim the whole panel
/// is built on, and until now it was only ever checked one level down, at the
/// monitor, where the delegate callbacks that actually carry the routes do not
/// exist.
func runActivityPanelTests() {

    // AppKit wants an application object before it will hand out fonts and
    // measure cells. Nothing is run and no window is shown; this only makes
    // NSApp exist.
    _ = NSApplication.shared

    // MARK: - fixtures

    /// A probe that measures nothing and counts everything done to it.
    final class CountingProbe: ActivityProbe {
        let name: String
        private let lock = NSLock()
        private var openCount = 0
        private var closeCount = 0
        private let failure: Error?

        init(name: String, failing: Error? = nil) {
            self.name = name
            self.failure = failing
        }

        // The monitor opens and closes probes on its own serial queue and the
        // test reads the counts from the main thread, so they are guarded.
        var opens: Int { lock.lock(); defer { lock.unlock() }; return openCount }
        var closes: Int { lock.lock(); defer { lock.unlock() }; return closeCount }

        func open() throws {
            if let failure { throw failure }
            lock.lock(); openCount += 1; lock.unlock()
        }

        func close() {
            lock.lock(); closeCount += 1; lock.unlock()
        }

        func read(into sample: inout ActivitySample) {}
    }

    struct Declined: Error, CustomStringConvertible {
        var description: String { "this Mac does not publish that counter" }
    }

    /// Let the sampling queue catch up. Everything the monitor does happens off
    /// the main thread, so a test that asserted straight after the call would
    /// be asserting against the instant before the work.
    func settle(_ condition: () -> Bool, within timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    let nowhere = Notification(name: NSPopover.didCloseNotification)

    func sample(cpuBusy: Double = 0.2, clusters: Int = 2, watts: Double? = 14.2,
                unavailable: [ProbeFailure] = []) -> ActivitySample {
        var s = ActivitySample(uptime: 100, interval: 1)
        s.cpu = CPUActivity(clusters: (0..<clusters).map { index in
            CPUActivity.Cluster(id: "P\(index)", kind: .performance,
                                cores: Array(repeating: cpuBusy, count: 4),
                                frequencyMHz: 3200, activeResidency: nil)
        })
        s.memory = MemoryActivity(used: 19_756_294_144, total: 25_769_803_776,
                                  app: 12_988_952_576, wired: 5_153_960_755,
                                  compressed: 1_610_612_736, cached: 4_294_967_296,
                                  swapUsed: 0, swapTotal: 0)
        if let watts {
            s.power = PowerActivity(cpuWatts: watts, gpuWatts: nil, aneWatts: nil, packageWatts: nil)
        }
        s.unavailable = unavailable
        return s
    }

    // MARK: - the tiles

    Check.suite("panel: a tile with nothing to say reserves nothing") {
        let gpu = ActivityGPUView()
        Check.equal(gpu.contentHeight, 0, "a Mac with no graphics counter has no graphics tile")

        var s = ActivitySample(uptime: 1, interval: 1)
        s.gpu = GPUActivity(utilization: 0.4, frequencyMHz: 1380)
        gpu.take(s)
        Check.equal(gpu.contentHeight, ActivityTheme.titleHeight + ActivityTheme.rowHeight,
                    "and once it has one, a title row and a meter row")
    }

    Check.suite("panel: a tile tells VoiceOver what it is") {
        Check.equal(ActivityCPUView().accessibilityLabel(), "Processor",
                    "the title row is drawn as CPU and read as a word")
        Check.equal(ActivityGPUView().accessibilityLabel(), "Graphics", "and so is the one below it")
        Check.equal(ActivityMemoryView().accessibilityLabel(), "Memory", "the rest are words already")
        Check.equal(ActivityHeaderView().accessibilityLabel(), "Machine",
                    "and the untitled nameplate says what it is instead of nothing")
    }

    Check.suite("panel: a tile grows with what it was given") {
        let cpu = ActivityCPUView()
        cpu.take(sample(clusters: 2))
        let two = cpu.contentHeight
        cpu.take(sample(clusters: 6))
        Check.close(Double(cpu.contentHeight - two), Double(ActivityTheme.rowHeight * 4),
                    tolerance: 0.0001, "four more clusters is four more rows")
    }

    Check.suite("power: a headline that is not a number is not a tile") {
        let tile = ActivityPowerView()
        var nonsense = ActivitySample(uptime: 1, interval: 1)
        nonsense.power = PowerActivity(cpuWatts: .nan, gpuWatts: nil, aneWatts: nil, packageWatts: nil)

        tile.take(nonsense)
        Check.that(!tile.hasContent, "a NaN leaves the tile as absent as a Mac with no counters")
        Check.equal(tile.contentHeight, 0, "so the panel reserves nothing for it")
        Check.isNil(tile.titleValue, "and no peak of zero is printed beside a headline nobody drew")

        tile.take(sample(watts: 8.0))
        tile.take(sample(watts: 9.5))
        Check.that(tile.hasContent, "a real reading brings the tile back")
        Check.equal(tile.titleValue, "peak 9.5 W", "with the highest of them")

        tile.take(nonsense)
        Check.equal(tile.titleValue, "peak 9.5 W",
                    "and a NaN arriving later is refused rather than recorded as a zero")

        var negative = ActivitySample(uptime: 1, interval: 1)
        negative.power = PowerActivity(cpuWatts: -3, gpuWatts: nil, aneWatts: nil, packageWatts: nil)
        tile.take(negative)
        Check.equal(tile.titleValue, "peak 9.5 W", "so is a negative one")
    }

    // MARK: - the footer

    /// How tall one line of a font is, near enough to tell one line from two.
    func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.boundingRectForFont.height) }

    /// What a footer field's own cell says it needs at the panel's width. The
    /// panel measures the same way; if it ever stops, this is what catches it.
    func drawnHeight(_ field: NSTextField) -> CGFloat {
        let unbounded = CGRect(x: 0, y: 0, width: ActivityTheme.content,
                               height: .greatestFiniteMagnitude)
        return ceil(field.cell?.cellSize(forBounds: unbounded).height ?? 0)
    }

    Check.suite("footer: the notice wraps rather than losing the names") {
        let panel = ActivityPanelView()
        let declined = ["energy", "graphics", "memory", "storage", "network"]
            .map { ProbeFailure(name: $0, reason: "\(Declined())") }
        panel.update(sample(unavailable: declined))

        Check.equal(panel.notice.stringValue,
                    "5 readings are unavailable on this Mac: energy, graphics, memory, "
                    + "storage, network.",
                    "every name is in the string")
        Check.equal(panel.notice.frame.height, drawnHeight(panel.notice),
                    "and the panel reserves exactly what the field draws")
        Check.that(panel.notice.frame.height > lineHeight(ActivityTheme.footnote) * 1.5,
                   "which is more than one line, because that sentence does not fit on one")
        Check.that(!panel.notice.isHidden, "and it is on screen")
        Check.unwrap(panel.notice.toolTip, "with the reasons behind a tooltip")
    }

    Check.suite("footer: one missing reading is one line") {
        let panel = ActivityPanelView()
        panel.update(sample(unavailable: [ProbeFailure(name: "energy", reason: "\(Declined())")]))
        Check.equal(panel.notice.frame.height, drawnHeight(panel.notice), "reserved is drawn")
        Check.that(panel.notice.frame.height < lineHeight(ActivityTheme.footnote) * 1.5,
                   "a short sentence takes one line and no more")
    }

    Check.suite("footer: nothing missing, nothing said") {
        let panel = ActivityPanelView()
        panel.update(sample())
        Check.equal(panel.notice.stringValue, "", "a Mac that answered everything has no notice")
        Check.equal(panel.notice.frame.height, 0, "and the panel reserves nothing for it")
        Check.that(panel.notice.isHidden, "nor draws it")
    }

    Check.suite("footer: the receipt says what the panel costs") {
        let panel = ActivityPanelView()
        panel.update(sample())

        Check.that(panel.receipt.stringValue.hasPrefix("This panel: 1 timer · 1 sample a second · Taurine "),
                   "the timer, the cadence and the app it belongs to")
        Check.that(panel.receipt.stringValue.hasSuffix(" MB"), "then the megabytes, live from the kernel")
        Check.equal(panel.receipt.frame.height, drawnHeight(panel.receipt), "reserved is drawn")
        Check.that(panel.receipt.frame.height < lineHeight(ActivityTheme.receipt) * 1.5,
                   "and it fits on one line at the panel's width, which is the point of a receipt")
        Check.unwrap(panel.receipt.toolTip, "the arithmetic behind it is a tooltip away")

        panel.forget()
        Check.equal(panel.receipt.stringValue, "",
                    "a closed panel costs nothing, so it claims nothing")
    }

    Check.suite("panel: the footer is part of the height the popover is given") {
        let bare = ActivityPanelView()
        bare.update(sample())
        let withoutNotice = bare.preferredHeight

        let noisy = ActivityPanelView()
        let declined = ["energy", "graphics", "memory", "storage", "network"]
            .map { ProbeFailure(name: $0, reason: "\(Declined())") }
        noisy.update(sample(unavailable: declined))

        Check.close(Double(noisy.preferredHeight - withoutNotice),
                    Double(noisy.notice.frame.height + 5),
                    tolerance: 0.0001,
                    "the wrapped notice and the gap under it, and nothing else")
    }

    Check.suite("panel: a section with nothing to say takes no gap with it") {
        let panel = ActivityPanelView()
        panel.update(sample(watts: nil))
        let withoutPower = panel.preferredHeight

        let full = ActivityPanelView()
        full.update(sample(watts: 14.2))
        Check.that(full.preferredHeight > withoutPower,
                   "the power tile is worth its height when there is power to show")
        Check.close(Double(full.preferredHeight - withoutPower),
                    Double(ActivityTheme.titleHeight + 40 + 16 + ActivityTheme.sectionGap),
                    tolerance: 0.0001,
                    "a title row, a headline, a parts row and the gap that separates it")
    }

    Check.suite("panel: a twenty-cluster chip is taller than the popover it opens in") {
        let panel = ActivityPanelView()
        panel.update(sample(clusters: 20))
        Check.that(panel.preferredHeight > ActivityTheme.maximumHeight,
                   "which is why the panel is inside a scroll view at all")
    }

    // MARK: - the shutter

    Check.suite("controller: opening starts the session, closing gives it back") {
        let probes = [CountingProbe(name: "one"), CountingProbe(name: "two")]
        let controller = ActivityPanelController(probes: probes)
        Check.that(!controller.isOpen, "a controller that was never shown is not open")

        controller.popoverWillShow(nowhere)
        Check.that(controller.isOpen, "the panel is up the moment the popover says it is")
        Check.that(settle { probes.allSatisfy { $0.opens == 1 } }, "every probe was opened")

        controller.popoverWillClose(nowhere)
        Check.that(!controller.isOpen, "and down the moment the dismissal begins")
        controller.popoverDidClose(nowhere)
        Check.that(settle { probes.allSatisfy { $0.closes == 1 } }, "every probe was closed")
    }

    Check.suite("controller: close is idempotent, and works on a panel never shown") {
        let probe = CountingProbe(name: "one")
        let controller = ActivityPanelController(probes: [probe])

        controller.close()
        Check.that(!controller.isOpen, "still shut")
        Check.equal(probe.opens, 0, "nothing was ever opened, so nothing had to be closed")

        controller.popoverWillShow(nowhere)
        Check.that(settle { probe.opens == 1 }, "opened")
        controller.close()
        controller.close()
        Check.that(settle { probe.closes == 1 }, "closed exactly once, however many times it is asked")
        Check.that(!controller.isOpen, "and it says so")
    }

    Check.suite("controller: hiding the app is one of the routes out") {
        let probe = CountingProbe(name: "one")
        let controller = ActivityPanelController(probes: [probe])

        controller.popoverWillShow(nowhere)
        Check.that(settle { probe.opens == 1 }, "opened")

        NotificationCenter.default.post(name: NSApplication.didHideNotification, object: NSApp)
        Check.that(settle { probe.closes == 1 }, "hiding Taurine closes the panel behind it")
        Check.that(!controller.isOpen, "and the panel knows it is gone")
    }

    Check.suite("controller: a re-open inside the close animation is not dropped") {
        let probe = CountingProbe(name: "one")
        let controller = ActivityPanelController(probes: [probe])

        controller.popoverWillShow(nowhere)
        Check.that(settle { probe.opens == 1 }, "the first session opened")

        // The dismissal begins. `NSPopover.isShown` stays true for the whole
        // half-second the animation runs, which is the window this is about.
        controller.popoverWillClose(nowhere)
        Check.that(!controller.isOpen,
                   "the panel is already not open, so the guard in `show` lets the next one through")

        // The next session starts before the old one has finished going away.
        controller.popoverWillShow(nowhere)
        Check.that(controller.isOpen, "and it is up again")

        // The straggler from the close that was cut short must not take the
        // session that replaced it down with it.
        controller.popoverDidClose(nowhere)
        Check.equal(probe.closes, 0, "the probe that is still being read was not closed underneath it")
        Check.that(controller.isOpen, "and the panel is still open")

        controller.close()
        Check.that(settle { probe.closes == 1 }, "the real close still closes it")
    }

    Check.suite("controller: a probe that declines does not take the session with it") {
        let good = CountingProbe(name: "good")
        let bad = CountingProbe(name: "bad", failing: Declined())
        let controller = ActivityPanelController(probes: [good, bad])

        controller.popoverWillShow(nowhere)
        Check.that(settle { good.opens == 1 }, "the probe that works is opened")
        Check.equal(bad.opens, 0, "the one that threw is not")

        controller.popoverWillClose(nowhere)
        controller.popoverDidClose(nowhere)
        Check.that(settle { good.closes == 1 }, "and the working one is closed on the way out")
        Check.equal(bad.closes, 0, "a probe that never opened is never closed")
    }
}
