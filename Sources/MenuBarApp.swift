import Cocoa

/// The rancher. 🤠
///
/// Owns the menu bar item and wires every part together: the assertion, the
/// intent engine, the bull, the inspector, the battery conscience, the hotkey.
/// Keep this file readable — it's the map of the whole app.
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // The parts.
    private var statusItem: NSStatusItem!
    private let assertion = PowerAssertion()
    private let intents = IntentEngine()
    private let battery = Battery()
    private var hotkey: Hotkey?

    // Live state.
    private var intent: Intent?               // nil == asleep-allowed (idle)
    private var isAwake: Bool { assertion.isHeld }

    // Persisted preferences.
    private let defaults = UserDefaults.standard
    private var alsoSystemSleep: Bool {
        get { defaults.bool(forKey: "alsoSystemSleep") }
        set { defaults.set(newValue, forKey: "alsoSystemSleep") }
    }
    private var batteryGuard: Bool {
        get { defaults.bool(forKey: "batteryGuard") }
        set { defaults.set(newValue, forKey: "batteryGuard") }
    }
    private var startAwake: Bool {
        get { defaults.bool(forKey: "startAwake") }
        set { defaults.set(newValue, forKey: "startAwake") }
    }

    // Menu items we mutate.
    private let statusHeader = NSMenuItem(title: "Taurine — idle", action: nil, keyEquivalent: "")
    private var whyItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var systemItem: NSMenuItem!
    private var batteryItem: NSMenuItem!
    private var startAwakeItem: NSMenuItem!
    private var diagItem: NSMenuItem!

    // MARK: - lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = buildMenu()
        render()

        // The reflex: global hotkey.
        hotkey = Hotkey { [weak self] in self?.toggle() }

        // Intents can end themselves (timer fires, watched app quits).
        intents.onReasonEnded = { [weak self] in self?.deactivate(reason: "reason ended") }

        // The conscience: react to power changes without polling.
        battery.onChange = { [weak self] in self?.enforceBatteryGuard() }

        // Let the CLI (`taurine on/off/toggle`) drive us.
        listenForCLI()

        // Optional: come up already holding the line.
        if startAwake { activate(.manual) }
    }

    // MARK: - the two verbs

    func toggle() { isAwake ? deactivate(reason: "toggled off") : activate(.manual) }

    /// Start holding the line for a given reason.
    func activate(_ intent: Intent) {
        self.intent = intent
        var guards: SleepGuard = [.display]
        if alsoSystemSleep { guards.insert(.system) }
        assertion.hold(guards, reason: intent.label)

        // Arm any self-ending behavior.
        switch intent {
        case .duration(let s): intents.countdown(seconds: s)
        case .untilProcessExits(let pid, _): intents.watch(pid: pid)
        default: intents.cancel()
        }

        Toast.shared.play(Bull.run, near: statusItem.button,
                          tint: NSColor(calibratedRed: 1.0, green: 0.28, blue: 0.28, alpha: 1),
                          caption: "awake — \(intent.label)")
        render()
        enforceBatteryGuard()
    }

    /// Let go.
    func deactivate(reason: String) {
        guard isAwake else { return }
        intents.cancel()
        assertion.release()
        intent = nil
        Toast.shared.play(Bull.stop, near: statusItem.button,
                          tint: NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.66, alpha: 1),
                          caption: reason)
        render()
    }

    // MARK: - battery conscience

    private func enforceBatteryGuard() {
        guard batteryGuard, isAwake, !battery.onACPower,
              let pct = battery.percent, pct < 20 else { return }
        deactivate(reason: "battery \(pct)% — Taurine stepped back")
    }

    // MARK: - appearance

    private func render() {
        guard let b = statusItem.button else { return }
        let symbol: String
        switch (isAwake, intent) {
        case (false, _):             symbol = "bolt.slash"
        case (true, .duration):      symbol = "bolt.badge.clock.fill"
        default:                     symbol = "bolt.fill"
        }
        b.image = Self.icon(symbol) ?? Self.icon("bolt.fill")
        b.toolTip = isAwake ? "Taurine — awake \(intent?.label ?? "")" : "Taurine — idle (Mac may sleep)"
        statusHeader.title = isAwake ? "🐂 awake — \(intent?.label ?? "")" : "🐂 idle — Mac may sleep"
    }

    /// SF Symbol as a template image, tolerant of symbols missing on old macOS.
    private static func icon(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Taurine")
        img?.isTemplate = true
        return img
    }

    // MARK: - menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        statusHeader.isEnabled = false
        menu.addItem(statusHeader)
        menu.addItem(.separator())

        add(menu, "Toggle  (⌃⌥⌘R)", #selector(toggleAction))

        // Keep awake for a while.
        let forMenu = NSMenu()
        for (title, secs) in [("15 minutes", 900.0), ("30 minutes", 1800.0),
                              ("1 hour", 3600.0), ("2 hours", 7200.0)] {
            let it = NSMenuItem(title: title, action: #selector(durationAction(_:)), keyEquivalent: "")
            it.representedObject = secs; it.target = self
            forMenu.addItem(it)
        }
        let forItem = NSMenuItem(title: "Keep awake for…", action: nil, keyEquivalent: "")
        forItem.submenu = forMenu
        menu.addItem(forItem)

        // Stay awake until an app quits (populated live on open).
        let untilItem = NSMenuItem(title: "Stay awake until an app quits…", action: nil, keyEquivalent: "")
        untilItem.submenu = NSMenu()
        untilItem.submenu?.delegate = self
        menu.addItem(untilItem)

        menu.addItem(.separator())

        // The truth serum.
        whyItem = NSMenuItem(title: "Why is my Mac awake?", action: nil, keyEquivalent: "")
        whyItem.submenu = NSMenu()
        whyItem.submenu?.delegate = self
        menu.addItem(whyItem)

        // The receipts (refreshed live whenever the menu opens).
        diagItem = NSMenuItem(title: Diagnostics.badge(activeTimers: 0), action: nil, keyEquivalent: "")
        diagItem.isEnabled = false
        menu.addItem(diagItem)

        menu.addItem(.separator())

        systemItem   = add(menu, "Also prevent system sleep", #selector(toggleSystem))
        batteryItem  = add(menu, "Auto-off under 20% on battery", #selector(toggleBatteryGuard))
        startAwakeItem = add(menu, "Start awake at launch", #selector(toggleStartAwake))
        loginItem    = add(menu, "Start at login", #selector(toggleLogin))

        menu.addItem(.separator())
        add(menu, "Quit Taurine", #selector(quit), key: "q")
        return menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        menu.addItem(it)
        return it
    }

    /// Refresh live/checkbox state whenever a menu opens (never while idle).
    func menuWillOpen(_ menu: NSMenu) {
        if menu == statusItem.menu {
            systemItem.state = alsoSystemSleep ? .on : .off
            batteryItem.state = batteryGuard ? .on : .off
            startAwakeItem.state = startAwake ? .on : .off
            loginItem.state = LoginItem.isEnabled ? .on : .off
            diagItem.title = Diagnostics.badge(activeTimers: intents.activeSourceCount)
            return
        }
        if menu == whyItem.submenu { populateWhy(menu); return }
        // Otherwise it's the "until an app quits" submenu.
        populateRunningApps(menu)
    }

    private func populateWhy(_ menu: NSMenu) {
        menu.removeAllItems()
        let holders = AssertionInspector.current()
        if holders.isEmpty {
            menu.addItem(withTitle: "Nothing is keeping your Mac awake.", action: nil, keyEquivalent: "")
            return
        }
        for h in holders {
            let it = NSMenuItem(title: h.line, action: nil, keyEquivalent: "")
            it.toolTip = "pid \(h.pid) — “\(h.name)”" + (h.timeout.map { "\n\($0)" } ?? "")
            it.isEnabled = false
            menu.addItem(it)
        }
    }

    private func populateRunningApps(_ menu: NSMenu) {
        menu.removeAllItems()
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in apps {
            let it = NSMenuItem(title: app.localizedName ?? "pid \(app.processIdentifier)",
                                action: #selector(untilAppAction(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = ["pid": app.processIdentifier,
                                    "name": app.localizedName ?? "app"] as [String: Any]
            menu.addItem(it)
        }
    }

    // MARK: - actions

    @objc private func toggleAction() { toggle() }

    @objc private func durationAction(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Double else { return }
        activate(.duration(secs))
    }

    @objc private func untilAppAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let pid = info["pid"] as? Int32,
              let name = info["name"] as? String else { return }
        activate(.untilProcessExits(pid: pid, name: name))
    }

    @objc private func toggleSystem() {
        alsoSystemSleep.toggle()
        if isAwake, let i = intent { activate(i) }   // re-apply with new guards
    }
    @objc private func toggleBatteryGuard() { batteryGuard.toggle(); enforceBatteryGuard() }
    @objc private func toggleStartAwake() { startAwake.toggle() }

    @objc private func toggleLogin() {
        if let err = LoginItem.toggle() {
            let a = NSAlert(); a.messageText = "Login item change failed"; a.informativeText = err
            a.runModal()
        }
    }

    @objc private func quit() { assertion.release(); NSApp.terminate(nil) }

    // MARK: - CLI bridge (taurine on/off/toggle)

    private func listenForCLI() {
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(forName: .init("io.github.john-athan.taurine.on"), object: nil, queue: .main) { [weak self] _ in
            self?.activate(.manual) }
        dc.addObserver(forName: .init("io.github.john-athan.taurine.off"), object: nil, queue: .main) { [weak self] _ in
            self?.deactivate(reason: "off (cli)") }
        dc.addObserver(forName: .init("io.github.john-athan.taurine.toggle"), object: nil, queue: .main) { [weak self] _ in
            self?.toggle() }
    }
}
