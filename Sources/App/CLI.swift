import Cocoa

/// The gate. 🚪
///
/// One binary, two lives:
///   • no args        → the menu bar app (a bull in your status bar)
///   • a subcommand   → a quick CLI that talks to the running app, or acts alone
///
/// This lets `taurine` feel like a native tool while still being the GUI.

/// `taurine batt [80|off]`. Reads state straight off disk and writes the limit
/// straight to disk; the daemon notices by itself. No running GUI required.
func chargeCLI(_ args: [String]) -> Int32 {
    guard let arg = args.first else {
        guard let s = ChargeState.read() else {
            print("🔋 Charge limiting isn't installed. Enable it from the Taurine menu.")
            return 0
        }
        print("🔋 \(s.summary)  [\(s.path.rawValue)]")
        return 0
    }

    // Escape hatch. Works whether or not the daemon is alive, which is the
    // entire point of it: it exists for when the daemon is *not* alive.
    if arg.lowercased() == "unlock" {
        if geteuid() == 0 { return ChargeDaemon.forcePermitCharging() }
        guard let exe = Bundle.main.executablePath ?? CommandLine.arguments.first else { return 1 }
        if let err = Admin.run("'\(exe)' --charge-unlock") {
            FileHandle.standardError.write(Data("taurine: \(err)\n".utf8))
            return 1
        }
        print("🔋 Charging permitted again.")
        return 0
    }

    guard ChargeInstaller.isInstalled else {
        FileHandle.standardError.write(Data(
            "taurine: charge limiting isn't installed yet. Enable it once from the Taurine menu.\n".utf8))
        return 1
    }

    let limit: Int?
    switch arg.lowercased() {
    case "off", "none", "100":
        limit = nil
    default:
        let lo = ChargeConfig.range.lowerBound, hi = ChargeConfig.range.upperBound
        guard let n = Int(arg), ChargeConfig.range.contains(n) else {
            FileHandle.standardError.write(Data(
                "taurine: limit must be between \(lo) and \(hi), or 'off'.\n".utf8))
            return 2
        }
        limit = n
    }

    if let err = ChargeConfig.write(limit) {
        FileHandle.standardError.write(Data("taurine: \(err)\n".utf8))
        return 1
    }
    print(limit.map { "🔋 Charging will stop at \($0)%." } ?? "🔋 Charge limit off; charging to 100%.")
    return 0
}

func runCLI(_ args: [String]) -> Int32? {
    guard let first = args.first else { return nil }   // no args → launch GUI

    switch first {
    case "--charge-unlock":
        // Re-entry point for `taurine batt unlock` after it elevates.
        return ChargeDaemon.forcePermitCharging()

    case "--charge-daemon":
        // Not a user-facing command: this is what the LaunchDaemon execs as root.
        // Deliberately handled before any AppKit touches the process.
        return ChargeDaemon().run()

    case "batt", "charge":
        return chargeCLI(Array(args.dropFirst()))

    case "--", "run":
        // taurine -- <command …>   (alone; holds the line for the command's life)
        let cmd = Array(args.dropFirst())
        return CommandMode.run(cmd)

    case "on", "off", "toggle":
        // Nudge the running menu bar app via a distributed notification.
        DistributedNotificationCenter.default()
            .postNotificationName(.init("io.github.john-athan.taurine.\(first)"), object: nil,
                                  userInfo: nil, deliverImmediately: true)
        print("🐂 taurine \(first) → sent. (Taurine.app must be running.)")
        return 0

    case "lock":
        // Standalone: locks the screen without asking anything to sleep, so
        // whatever this terminal started is still running a second later.
        if let err = ScreenLock.now() {
            FileHandle.standardError.write(Data("taurine: \(err)\n".utf8))
            return 1
        }
        return 0

    case "lockable":
        // The stored answer, readable and writable from a script.
        let arg = args.dropFirst().first?.lowercased()
        switch arg {
        case "on", "yes", "1":   AwakeShape.letsScreenLock = true
        case "off", "no", "0":   AwakeShape.letsScreenLock = false
        case nil:                break
        default:
            FileHandle.standardError.write(Data("taurine: lockable takes 'on' or 'off'.\n".utf8))
            return 2
        }
        if arg != nil {
            // A session already being held was created with the old shape, so
            // tell the app to re-hold rather than leaving the two disagreeing.
            DistributedNotificationCenter.default()
                .postNotificationName(.init("io.github.john-athan.taurine.lockable"), object: nil,
                                      userInfo: nil, deliverImmediately: true)
        }
        let policy = LockPolicy.current()
        if AwakeShape.letsScreenLock {
            print("🔒 Awake sessions let the screen lock; the Mac keeps working.")
            print("   \(policy.summary)")
            if let w = policy.warning { print("   ⚠️  \(w)") }
        } else {
            print("🔒 Awake sessions keep the screen lit (`taurine lockable on` to change that).")
        }
        return 0

    case "why", "status":
        // Standalone: who's keeping this Mac awake right now?
        let holders = AssertionInspector.current()
        if holders.isEmpty { print("🐂 Nothing is keeping your Mac awake."); return 0 }
        print("🐂 Keeping your Mac awake right now:")
        for h in holders {
            print("   • \(h.process) (pid \(h.pid)) — \(h.type)")
            if let t = h.timeout { print("     \(t)") }
        }
        return 0

    case "-h", "--help", "help":
        print("""
        taurine — keep your Mac awake, with a reason. 🐂

          taurine                 launch the menu bar app
          taurine on|off|toggle   drive the running app
          taurine -- <command>    stay awake for a command's lifetime
          taurine why             show who's keeping the Mac awake
          taurine lock            lock the screen now, without sleeping
          taurine lockable [on|off]
                                  let the screen lock while awake (Mac keeps working)
          taurine batt            show the charge limit
          taurine batt 80         stop charging at 80%
          taurine batt off        charge to 100% again
          taurine batt unlock     force-permit charging (if the daemon ever dies)
          taurine help            this text
        """)
        return 0

    default:
        FileHandle.standardError.write(Data("taurine: unknown command '\(first)'. Try `taurine help`.\n".utf8))
        return 2
    }
}
