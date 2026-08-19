import Foundation

/// The stall door. 🔒
///
/// Locking the screen and staying awake look like opposites, and in every other
/// caffeine app they are. They are only tangled because of one assertion: hold
/// `PreventUserIdleDisplaySleep` and macOS can never turn the screen off, so it
/// can never start a screen saver either, so the idle lock everybody configures
/// in System Settings simply never fires. Nothing about the lock itself is in
/// the way. Drop that one assertion, keep `PreventUserIdleSystemSleep`, and the
/// Mac runs at full speed with the screen dark and locked. On the command line
/// this shape has a name already: `caffeinate -i`.
///
/// So the feature is mostly a subtraction, and the interesting part is what is
/// left over:
///
///   • The *automatic* lock is macOS's own display sleep timer, not ours. That
///     is deliberate. A lock has to be idle-aware, or it fires while you are
///     typing, and the only idle clock that costs nothing is the one the window
///     server is already running. Taurine adds no timer here, which is why the
///     diagnostics badge still reads 0 while this mode is on.
///   • The *manual* lock is `SACLockScreenImmediate`, which is the call behind
///     the Apple menu's Lock Screen item. It locks without asking anything to
///     sleep, so it is the gesture to use when processes must keep running.
///   • What an idle assertion cannot do is refuse a sleep somebody asked for.
///     Apple menu > Sleep, a closed lid, and on many Macs the power button all
///     take a path no assertion sees. `LockPolicy` reads the two settings that
///     decide that, so the menu can say so instead of the user finding out by
///     losing a build.
enum ScreenLock {

    /// Lock the screen right now, without asking the Mac to sleep.
    /// Returns nil on success, or a human message.
    @discardableResult
    static func now() -> String? {
        if let lock = immediateLock {
            let rc = lock()
            return rc == 0 ? nil : "the system's lock call refused (\(rc))."
        }
        return displaySleepNow()
    }

    /// Whether the immediate lock is available on this macOS. False means the
    /// fallback below is what a lock request will actually do, which is a
    /// different promise, so the menu is allowed to ask.
    static var locksImmediately: Bool { immediateLock != nil }

    private typealias LockFn = @convention(c) () -> Int32

    /// Resolved once, on first use, and then kept. `login` is private, so the
    /// symbol is fetched with `dlsym` and a missing one is a fallback rather
    /// than a crash on launch, which is the same bargain ADR 3 struck for
    /// IOReport. The handle is deliberately never closed: loginwindow acts on
    /// this call asynchronously, and unmapping the code underneath it is a
    /// crash looking for a slow machine.
    private static let immediateLock: LockFn? = {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockFn.self)
    }()

    /// The fallback. Turns the display off; whether that locks is then up to
    /// the "Require password after the screen turns off" setting.
    private static func displaySleepNow() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        p.standardOutput = Pipe()
        let errPipe = Pipe()
        p.standardError = errPipe
        do { try p.run() } catch {
            return "couldn't run pmset: \(error.localizedDescription)"
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return msg.isEmpty ? "pmset failed (exit \(p.terminationStatus))." : msg
        }
        return nil
    }
}

/// What macOS itself will do when you stop touching the Mac, read from the
/// kernel's own power settings rather than assumed.
///
/// Two numbers decide whether "awake, but locked" behaves the way somebody
/// expects, and both live outside Taurine:
///   • `displaysleep`, the minutes of no input before the screen goes dark.
///     Zero means never, and never means no automatic lock, no matter what the
///     Lock Screen settings say.
///   • `Sleep On Power Button`, because a power button that sleeps the Mac ends
///     every process the user was trying to protect, and no assertion can stop
///     it. Better to say so in a tooltip than to be surprised by it.
struct LockPolicy: Equatable {

    /// Minutes of no input before the display sleeps. nil when it never does.
    var displaySleepMinutes: Int?
    /// Whether a press of the power button asks this Mac to sleep.
    var sleepsOnPowerButton: Bool

    /// Read the live settings. Only ever called when a menu opens or a command
    /// runs, never on a schedule.
    static func current() -> LockPolicy { parse(pmsetOutput()) }

    /// The parser, kept separate from the process so it can be tested against
    /// real captured output instead of against whatever this Mac feels today.
    ///
    /// The block being read is the "Currently in use" one, whose lines look
    /// like `displaysleep         10 (display sleep prevented by taurine)` and
    /// `Sleep On Power Button 1`. Note that the second one has spaces in its
    /// name, so this matches on a known prefix rather than splitting columns.
    static func parse(_ pmsetOutput: String) -> LockPolicy {
        var minutes: Int? = nil
        var powerButton = false

        for raw in pmsetOutput.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("displaysleep") {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                if fields.count > 1, let n = Int(fields[1]) { minutes = n == 0 ? nil : n }
            } else if line.hasPrefix("Sleep On Power Button") {
                let rest = line.dropFirst("Sleep On Power Button".count)
                             .trimmingCharacters(in: .whitespaces)
                powerButton = rest.split(separator: " ").first.map { $0 == "1" } ?? false
            }
        }
        return LockPolicy(displaySleepMinutes: minutes, sleepsOnPowerButton: powerButton)
    }

    /// One line for the tooltip: when, if ever, the Mac locks on its own.
    var summary: String {
        guard let m = displaySleepMinutes else {
            return "This display is set to never turn off, so macOS will never lock it on its own."
        }
        let unit = m == 1 ? "minute" : "minutes"
        return "macOS turns this display off after \(m) \(unit) of no input; "
             + "your Lock Screen setting decides how soon after that it asks for a password."
    }

    /// The thing that will bite, if anything will. nil when nothing is in the way.
    var warning: String? {
        if displaySleepMinutes == nil {
            return "Nothing will start the lock: set \"Turn display off when inactive\" in "
                 + "System Settings > Lock Screen, or lock by hand."
        }
        if sleepsOnPowerButton {
            return "The power button is set to sleep this Mac, and a sleep you asked for is the "
                 + "one thing an assertion cannot refuse. Lock with ⌃⌘Q or with Taurine instead."
        }
        return nil
    }

    private static func pmsetOutput() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Which assertions an awake session holds.
///
/// This lives next to the lock rather than inside the menu bar app because the
/// CLI holds its own assertions for `taurine -- <command>`, and a Mac that
/// locks under the menu item but blazes away under the command would be two
/// features wearing one name.
enum AwakeShape {

    static let letScreenLockKey = "letScreenLock"

    /// Off by default: awake has always meant a lit screen, and changing what
    /// an existing install does on upgrade is not this feature's business.
    static var letsScreenLock: Bool {
        get { UserDefaults.standard.bool(forKey: letScreenLockKey) }
        set { UserDefaults.standard.set(newValue, forKey: letScreenLockKey) }
    }

    /// The whole decision, as arithmetic on two stored answers.
    ///
    /// When the screen is allowed to lock, the system guard is not optional and
    /// the display guard is not held: dropping the display assertion is what
    /// makes the lock possible, and the system assertion is then the only thing
    /// still holding the Mac up. `alsoSystemSleep` stops being a choice there,
    /// so the menu shows it as on and disabled rather than letting somebody
    /// switch off the last leg they are standing on.
    static func guards(letScreenLock: Bool, alsoSystemSleep: Bool) -> SleepGuard {
        if letScreenLock { return [.system] }
        var g: SleepGuard = [.display]
        if alsoSystemSleep { g.insert(.system) }
        return g
    }
}
