import Foundation

/// The reason to be awake. 🎯
///
/// This is the wedge. Every other app toggles a *state*. Taurine binds wakeing
/// to an *intent* and lets it end on its own:
///   • stay awake until this command finishes
///   • stay awake until that process exits
///   • stay awake for N minutes, then stop
///
/// Note how none of these poll. Command + PID watching use kernel process
/// events (`DispatchSource.makeProcessSource`), the timer uses a one-shot
/// dispatch timer that only exists while a session is live. Idle cost: zero.
enum Intent {
    case manual                       // classic toggle, no auto-release
    case duration(TimeInterval)       // stop after N seconds
    case untilProcessExits(pid: Int32, name: String)
    case forCommand(String)           // CLI: alive for a child command's life

    var label: String {
        switch self {
        case .manual: return "manual"
        case .duration(let s): return "for \(Int(s / 60))m"
        case .untilProcessExits(_, let n): return "until \(n) exits"
        case .forCommand(let c): return "while `\(c)` runs"
        }
    }
}

final class IntentEngine {
    private var timer: DispatchSourceTimer?
    private var procWatch: DispatchSourceProcess?

    /// Called when an intent decides on its own that the reason is over.
    var onReasonEnded: (() -> Void)?

    /// How many live dispatch sources we're holding right now (0 when idle).
    /// The Diagnostics badge reports this so "N timers" is measured, not claimed.
    var activeSourceCount: Int {
        (timer != nil ? 1 : 0) + (procWatch != nil ? 1 : 0)
    }

    /// Watch a PID; when it exits, the reason is over. Kernel-driven, no polling.
    func watch(pid: Int32) {
        cancel()
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in
            self?.procWatch?.cancel()
            self?.procWatch = nil
            self?.onReasonEnded?()
        }
        src.resume()
        procWatch = src
    }

    /// Fire once after `seconds`, then the reason is over.
    func countdown(seconds: TimeInterval) {
        cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + seconds)
        t.setEventHandler { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.onReasonEnded?()
        }
        t.resume()
        timer = t
    }

    /// Tear down any live watchers. Safe to call repeatedly.
    func cancel() {
        timer?.cancel(); timer = nil
        procWatch?.cancel(); procWatch = nil
    }

    deinit { cancel() }
}

/// CLI command mode: `taurine -- make build`.
/// Holds display+system assertions for exactly the child's lifetime, with a
/// bull in the terminal so you can see it working. This is `caffeinate cmd`
/// with a pulse.
enum CommandMode {
    static func run(_ argv: [String]) -> Int32 {
        guard !argv.isEmpty else {
            FileHandle.standardError.write(Data("taurine: nothing to run after --\n".utf8))
            return 2
        }
        let pretty = argv.joined(separator: " ")
        let assertion = PowerAssertion()
        assertion.hold([.display, .system], reason: "command: \(pretty)")

        print(Bull.charging)
        print("🐂 taurine — holding the line while `\(pretty)` runs…\n")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        // Inherit the terminal so the child behaves normally.
        p.standardInput = FileHandle.standardInput
        p.standardOutput = FileHandle.standardOutput
        p.standardError = FileHandle.standardError

        do { try p.run() } catch {
            assertion.release()
            FileHandle.standardError.write(Data("taurine: could not run \(argv[0]): \(error.localizedDescription)\n".utf8))
            return 127
        }
        p.waitUntilExit()
        assertion.release()

        print("\n" + Bull.grazing)
        print("🐂 done — Taurine let go. (`\(pretty)` exited \(p.terminationStatus))")
        return p.terminationStatus
    }
}
