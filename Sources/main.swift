import Cocoa

/// The gate. 🚪
///
/// One binary, two lives:
///   • no args        → the menu bar app (a bull in your status bar)
///   • a subcommand   → a quick CLI that talks to the running app, or acts alone
///
/// This lets `taurine` feel like a native tool while still being the GUI.
func runCLI(_ args: [String]) -> Int32? {
    guard let first = args.first else { return nil }   // no args → launch GUI

    switch first {
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
          taurine help            this text
        """)
        return 0

    default:
        FileHandle.standardError.write(Data("taurine: unknown command '\(first)'. Try `taurine help`.\n".utf8))
        return 2
    }
}

let argv = Array(CommandLine.arguments.dropFirst())
if let code = runCLI(argv) {
    exit(code)
}

// No subcommand → be the bull in the menu bar.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)          // menu bar only, no Dock icon
let controller = MenuBarApp()
app.delegate = controller
app.run()
