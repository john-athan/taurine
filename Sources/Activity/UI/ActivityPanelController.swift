import Cocoa

/// The shutter. 🎛️
///
/// Opens the panel, and closes everything behind it. This is the object that
/// makes ADR 0002 true: the monitor starts in `popoverWillShow` and stops in
/// `popoverDidClose`, and there is no third path. Click away, hit escape, hide
/// the app, quit: every one of them ends at `popoverDidClose`, the timer is
/// cancelled, every probe is closed and the panel's minute of history is thrown
/// away. The badge goes back to reading `0 timers` because it genuinely is.
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
        scroll.hasVerticalScroller = false
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

    var isOpen: Bool { popover.isShown }

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
        guard !popover.isShown else { return }

        // Without this the popover appears behind whatever is frontmost, since
        // Taurine is an accessory app and is never active on its own.
        NSApp.activate(ignoringOtherApps: true)
        popover.animates = !ActivityTheme.prefersReducedMotion
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// Close the panel and give everything back. Idempotent.
    func close() {
        popover.performClose(nil)
        stopAndForget()
    }

    // MARK: - lifecycle

    func popoverWillShow(_ notification: Notification) {
        monitor.start(interval: Self.interval)
    }

    func popoverDidClose(_ notification: Notification) {
        stopAndForget()
    }

    @objc private func appWentAway() {
        guard isOpen else { return }
        close()
    }

    private func stopAndForget() {
        monitor.stop()
        panel.forget()
    }

    // MARK: - samples

    private func received(_ sample: ActivitySample) {
        panel.update(sample)

        let height = min(panel.preferredHeight, ActivityTheme.maximumHeight)
        let size = CGSize(width: ActivityTheme.width, height: height)
        guard popover.contentSize != size else { return }
        popover.contentSize = size
    }
}
