import Cocoa

/// The gate.
///
/// One binary, two lives:
///   • no args        → the menu bar app (a bull in your status bar)
///   • a subcommand   → a quick CLI that talks to the running app, or acts alone
///
/// This lets `taurine` feel like a native tool while still being the GUI.

/// `taurine batt`. The charge limit is a macOS setting now (ADR 11); this
/// only points there, for the fingers that still type it.
func chargeCLI() -> Int32 {
    print("🔋 Charge limiting is built into macOS now: System Settings → Battery.")
    if OldChargeDaemon.isInstalled {
        print("   The daemon an older Taurine installed is still here. Remove it from the Taurine menu.")
    }
    return 0
}

func runCLI(_ args: [String]) -> Int32? {
    guard let first = args.first else { return nil }   // no args → launch GUI

    switch first {
    case "batt", "charge":
        return chargeCLI()

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
            print("   • \(h.process) (pid \(h.pid)), \(h.type)")
            if let t = h.timeout { print("     \(t)") }
        }
        return 0

    case "-h", "--help", "help":
        print("""
        taurine, keep your Mac awake, with a reason. 🐂

          taurine                 launch the menu bar app
          taurine on|off|toggle   drive the running app
          taurine -- <command>    stay awake for a command's lifetime
          taurine why             show who's keeping the Mac awake
          taurine lock            lock the screen now, without sleeping
          taurine lockable [on|off]
                                  let the screen lock while awake (Mac keeps working)
          taurine help            this text
        """)
        return 0

    default:
        FileHandle.standardError.write(Data("taurine: unknown command '\(first)'. Try `taurine help`.\n".utf8))
        return 2
    }
}
