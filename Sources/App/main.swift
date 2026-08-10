import Cocoa

/// The ignition. 🔑
///
/// Every decision about *what* this invocation is lives in `CLI.swift`; this
/// file is only the six lines that can't live anywhere else, because Swift
/// insists top-level code sit in a file called `main.swift`. Keeping it this
/// thin is what lets the test binary link the whole app minus this one file.

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
