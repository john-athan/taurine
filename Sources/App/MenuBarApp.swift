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
    private let clamshell = ClamshellGuard()
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
    /// Off by default: closing the lid should sleep the Mac like normal.
    /// On, and only while awake + on AC power, we hold the lid open too.
    private var lidAwake: Bool {
        get { defaults.bool(forKey: "lidAwake") }
        set { defaults.set(newValue, forKey: "lidAwake") }
    }

    // Menu items we mutate.
    private let statusHeader = NSMenuItem(title: "Taurine — idle", action: nil, keyEquivalent: "")
    private var whyItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var systemItem: NSMenuItem!
    private var batteryItem: NSMenuItem!
    private var startAwakeItem: NSMenuItem!
    private var lidItem: NSMenuItem!
    private var diagItem: NSMenuItem!
    private var chargeItem: NSMenuItem!

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
        battery.onChange = { [weak self] in
            self?.enforceBatteryGuard()
            self?.enforceLidGuard()          // unplugged → drop the lid-open flag
        }

        // Let the CLI (`taurine on/off/toggle`) drive us.
        listenForCLI()

        // Optional: come up already holding the line.
        if startAwake { activate(.manual) }
    }

    /// Belt and suspenders: whatever tears us down, put the lid flag back.
    func applicationWillTerminate(_ n: Notification) {
        clamshell.revertQuietly()
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
        enforceLidGuard()
    }

    /// Let go.
    func deactivate(reason: String) {
        guard isAwake else { return }
        intents.cancel()
        assertion.release()
        intent = nil
        enforceLidGuard()                 // no longer awake → let the lid sleep again
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

    // MARK: - lid conscience

    /// Drive the clamshell flag to match reality. Engaged only when the user
    /// opted in *and* we're awake *and* on wall power; dropped otherwise. Silent
    /// on background triggers (unplug, deactivate) — only the menu toggle surfaces
    /// an admin failure, via `toggleLid`.
    @discardableResult
    private func enforceLidGuard() -> String? {
        let want = lidAwake && isAwake && battery.onACPower
        let err = clamshell.set(want)
        render()
        return err
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
        let lid = clamshell.active ? " · lid held" : ""
        b.toolTip = isAwake ? "Taurine — awake \(intent?.label ?? "")\(lid)" : "Taurine — idle (Mac may sleep)"
        statusHeader.title = isAwake ? "🐂 awake — \(intent?.label ?? "")\(lid)" : "🐂 idle — Mac may sleep"
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

        // The charge limit. Owned by a root daemon, not by this process; this
        // submenu only writes a number to a file the daemon is watching.
        chargeItem = NSMenuItem(title: "Charge limit", action: nil, keyEquivalent: "")
        chargeItem.submenu = NSMenu()
        chargeItem.submenu?.delegate = self
        menu.addItem(chargeItem)

        menu.addItem(.separator())

        systemItem   = add(menu, "Also prevent system sleep", #selector(toggleSystem))
        lidItem      = add(menu, "Keep awake with lid closed (AC only)", #selector(toggleLid))
        lidItem.toolTip = "Needs admin. Blocks lid-close sleep while awake and plugged in. "
                        + "Reverts on unplug, toggle-off, or quit. Careful: an awake Mac in a closed bag can overheat."
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
            lidItem.state = lidAwake ? .on : .off
            batteryItem.state = batteryGuard ? .on : .off
            startAwakeItem.state = startAwake ? .on : .off
            loginItem.state = LoginItem.isEnabled ? .on : .off
            diagItem.title = Diagnostics.badge(activeTimers: intents.activeSourceCount)
            chargeItem.title = "Charge limit: " + (ChargeState.read()?.summary ?? "off")
            return
        }
        if menu == whyItem.submenu { populateWhy(menu); return }
        if menu == chargeItem.submenu { populateCharge(menu); return }
        // Otherwise it's the "until an app quits" submenu.
        populateRunningApps(menu)
    }

    /// Built fresh on open, from the state file the daemon last wrote. Nothing
    /// here is cached or watched, so an unopened menu costs nothing.
    private func populateCharge(_ menu: NSMenu) {
        menu.removeAllItems()

        guard ChargeInstaller.isInstalled else {
            let it = NSMenuItem(title: "Enable charge limiting…", action: #selector(installCharge), keyEquivalent: "")
            it.target = self
            it.toolTip = "Installs a small root daemon that stops charging at your chosen level. "
                       + "Asks for admin once, then never again."
            menu.addItem(it)
            return
        }

        let state = ChargeState.read()

        if let state, !state.path.isSupported {
            let it = NSMenuItem(title: "Not supported on this Mac", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
            return
        }

        let header = NSMenuItem(title: state?.summary ?? "starting up…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let current = state?.limit
        for pct in [60, 70, 75, 80, 85, 90] {
            let it = NSMenuItem(title: "\(pct)%", action: #selector(setChargeLimit(_:)), keyEquivalent: "")
            it.representedObject = pct
            it.target = self
            it.state = (current == pct) ? .on : .off
            menu.addItem(it)
        }

        let off = NSMenuItem(title: "Off (charge to 100%)", action: #selector(setChargeLimit(_:)), keyEquivalent: "")
        off.representedObject = nil as Int?
        off.target = self
        off.state = (current == nil) ? .on : .off
        menu.addItem(off)

        menu.addItem(.separator())

        // The daemon runs a root-owned *copy* of this binary, so rebuilding the
        // app leaves the copy behind. Say so rather than pretending they match.
        if ChargeInstaller.isStale {
            let it = NSMenuItem(title: "Update charge daemon…", action: #selector(installCharge), keyEquivalent: "")
            it.target = self
            it.toolTip = "Taurine has been rebuilt since the root daemon was installed. "
                       + "This copies the new binary and restarts it."
            menu.addItem(it)
        }

        let rm = NSMenuItem(title: "Remove charge daemon…", action: #selector(uninstallCharge), keyEquivalent: "")
        rm.target = self
        rm.toolTip = "Stops the daemon and re-enables normal charging."
        menu.addItem(rm)

        if let state, state.path != .unsupported {
            let dbg = NSMenuItem(title: "via SMC \(state.path.rawValue)", action: nil, keyEquivalent: "")
            dbg.isEnabled = false
            menu.addItem(dbg)
        }
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

    @objc private func toggleLid() {
        lidAwake.toggle()
        // If enabling failed the admin step (e.g. cancelled), fall back to off
        // so the checkbox never lies about what's really in effect.
        if let err = enforceLidGuard(), lidAwake {
            lidAwake = false
            enforceLidGuard()
            let a = NSAlert(); a.messageText = "Couldn't keep the lid awake"; a.informativeText = err
            a.runModal()
        } else if lidAwake && !battery.onACPower {
            Toast.shared.play(Bull.stop, near: statusItem.button,
                              tint: NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.66, alpha: 1),
                              caption: "lid guard armed — engages on AC power")
        }
    }

    // MARK: - charge limit

    @objc private func installCharge() {
        if let err = ChargeInstaller.install() {
            let a = NSAlert(); a.messageText = "Couldn't install charge limiting"; a.informativeText = err
            a.runModal()
            return
        }
        // Give a fresh daemon a sensible default, but don't stomp an existing
        // choice when this same item is used to refresh a stale helper.
        let existing = ChargeConfig.read()
        if existing == nil { _ = ChargeConfig.write(80) }
        Toast.shared.play(Bull.stop, near: statusItem.button,
                          tint: NSColor(calibratedRed: 0.36, green: 0.72, blue: 0.42, alpha: 1),
                          caption: "charge limit \(existing ?? 80)%")
    }

    @objc private func setChargeLimit(_ sender: NSMenuItem) {
        let limit = sender.representedObject as? Int
        if let err = ChargeConfig.write(limit) {
            let a = NSAlert(); a.messageText = "Couldn't set the charge limit"; a.informativeText = err
            a.runModal()
            return
        }
        Toast.shared.play(Bull.stop, near: statusItem.button,
                          tint: NSColor(calibratedRed: 0.36, green: 0.72, blue: 0.42, alpha: 1),
                          caption: limit.map { "charge limit \($0)%" } ?? "charging to 100%")
    }

    @objc private func uninstallCharge() {
        if let err = ChargeInstaller.uninstall() {
            let a = NSAlert(); a.messageText = "Couldn't remove the charge daemon"; a.informativeText = err
            a.runModal()
        }
    }

    @objc private func toggleLogin() {
        if let err = LoginItem.toggle() {
            let a = NSAlert(); a.messageText = "Login item change failed"; a.informativeText = err
            a.runModal()
        }
    }

    @objc private func quit() {
        assertion.release()
        clamshell.revertQuietly()          // never leave the lid flag set behind us
        NSApp.terminate(nil)
    }

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
