import Cocoa

/// The shutter. 🎛️
///
/// Opens the panel, and closes everything behind it. This is the object that
/// makes ADR 0002 true: the monitor starts in `popoverWillShow` and stops in
/// `popoverDidClose`, and there is no third path. Click away, hit escape, hide
/// the app, quit: every one of them ends at `popoverDidClose`, the timer is
/// cancelled, every probe is closed and the panel's minute of history is thrown
/// away. The receipt the panel printed while it was open stops being true the
/// instant it stops being drawn, which is the point of printing it there rather
/// than in the menu the panel cannot coexist with.
///
/// The probes arrive as an init parameter rather than being built here. This
/// file knows how to run a panel; it does not know how to read IOReport, and
/// keeping it that way is what lets the probes be tested, replaced or simply
/// absent without the panel noticing. A Mac where every probe fails to open
/// still shows a panel, with a footer explaining itself.
///
/// The trap: `NSPopover` is not required to send `popoverDidClose` for a
/// popover that was never shown, and `close()` on an unshown popover does
/// nothing. So the monitor's lifecycle hangs off the delegate callbacks and not
/// off the `show` and `close` methods, which would otherwise start a sampler
/// that nothing ever stops on the day a popover declines to appear. `stop()`
/// is idempotent, so the belt-and-braces call in `close()` is free.
///
/// The second trap, which is the same trap read the other way: `isShown` is not
/// the question "is the panel up". It stays true for the whole half-second the
/// dismissal animates, so a panel asked for again inside that window would be
/// asked for while the old one is still nominally on screen. `isOpen` is
/// tracked from `popoverWillShow` and `popoverWillClose` instead, which are the
/// two moments the answer actually changes.
final class ActivityPanelController: NSObject, NSPopoverDelegate {

    /// One second. Fast enough that the sparklines move, slow enough that the
    /// panel costs less than what it is measuring.
    static let interval: TimeInterval = 1.0

    private let monitor: ActivityMonitor
    private let panel = ActivityPanelView()
    private let popover = NSPopover()
    private let scroll = NSScrollView()

    /// - Parameter probes: everything the panel should try to read. Handed in
    ///   so that this file depends on the protocol and not on any probe.
    init(probes: [ActivityProbe]) {
        monitor = ActivityMonitor(probes: probes)
        super.init()

        // A scroll view, not because the panel scrolls on this Mac, but because
        // a chip with more clusters than this one would otherwise produce a
        // popover taller than the screen it opens on.
        //
        // The scroller is real, and overlay in both senses: it costs no width
        // on the Macs that never need it, and the panel's width is fixed, so a
        // legacy scroller would take fifteen points out of the content and set
        // the whole thing scrolling sideways as well. Content that runs past
        // the cap with nothing on screen to say so is content nobody scrolls
        // to, so `received` flashes the scroller the first time a session grows
        // past the cap, which is the platform's own way of saying "more below".
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = panel
        scroll.contentView.postsBoundsChangedNotifications = false

        let controller = NSViewController()
        controller.view = scroll

        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = CGSize(width: ActivityTheme.width, height: 240)

        monitor.onSample = { [weak self] sample in self?.received(sample) }

        NotificationCenter.default.addObserver(
            self, selector: #selector(appWentAway),
            name: NSApplication.didHideNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        monitor.stop()
    }

    /// Whether the panel is up and staying up. False from the moment a close
    /// begins, which is a good half-second before the popover stops being
    /// `isShown`.
    private(set) var isOpen = false

    // MARK: - the two verbs

    /// Show the panel under `anchor`, which in the app is the status item's
    /// button. Safe to call when it is already open, which is what makes it
    /// usable straight from a menu item.
    ///
    /// The anchor is an `NSView` rather than an `NSStatusBarButton` because
    /// that is all `NSPopover` wants, and narrowing it would buy no safety
    /// while making the panel impossible to stand up anywhere except the menu
    /// bar. `statusItem.button` passes straight in.
    func show(relativeTo anchor: NSView?) {
        guard let anchor, anchor.window != nil else { return }
        guard !isOpen else { return }

        // A dismissal that is still animating leaves the popover `isShown`, and
        // `show` on a popover that is already shown does nothing at all. Ending
        // the animation here is what turns "dismiss the panel and ask for it
        // straight back" from a click that vanishes into a panel that reopens.
        // The forced close runs the ordinary teardown through
        // `popoverDidClose`, so the session that is going away is still closed
        // properly before the next one starts.
        if popover.isShown {
            popover.animates = false
            popover.close()
        }

        // Without this the popover appears behind whatever is frontmost, since
        // Taurine is an accessory app and is never active on its own.
        NSApp.activate(ignoringOtherApps: true)
        popover.animates = !ActivityTheme.prefersReducedMotion
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// Close the panel and give everything back. Idempotent.
    ///
    /// `isOpen` is answered here rather than left to `popoverWillClose`,
    /// because a popover that was never shown sends neither callback and the
    /// panel would then claim to be up for the rest of the process.
    func close() {
        isOpen = false
        popover.performClose(nil)
        stopAndForget()
    }

    // MARK: - lifecycle

    func popoverWillShow(_ notification: Notification) {
        isOpen = true
        monitor.start(interval: Self.interval)
    }

    /// The panel is on its way out from here, whichever route asked for it.
    /// Nothing is torn down yet: `didClose` does that, once the animation has
    /// finished and the popover is genuinely gone.
    func popoverWillClose(_ notification: Notification) {
        isOpen = false
    }

    func popoverDidClose(_ notification: Notification) {
        // A close that a re-open overtook: `show` cut the animation short and
        // has already started the next session. Tearing down here would stop
        // the timer of a panel that is on screen.
        guard !isOpen else { return }
        stopAndForget()
    }

    @objc private func appWentAway() {
        guard isOpen else { return }
        close()
    }

    private func stopAndForget() {
        monitor.stop()
        panel.forget()
        flashedScrollers = false
    }

    // MARK: - samples

    /// Whether this session has already been told there is more below. Once
    /// per session: a scroller that flashed every second would be a tic.
    private var flashedScrollers = false

    private func received(_ sample: ActivitySample) {
        panel.update(sample)

        let wanted = panel.preferredHeight
        let size = CGSize(width: ActivityTheme.width,
                          height: min(wanted, ActivityTheme.maximumHeight))

        if wanted > ActivityTheme.maximumHeight, !flashedScrollers {
            flashedScrollers = true
            scroll.flashScrollers()
        }

        guard popover.contentSize != size else { return }
        popover.contentSize = size
    }
}
