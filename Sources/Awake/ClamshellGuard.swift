import Foundation

/// The stubborn horn. 🐂🔒
///
/// Idle power assertions (the rest of Taurine) do **not** survive a closed lid —
/// that's *clamshell* sleep, a separate kernel path. The only supported lever is
/// `pmset disablesleep`, a system-wide flag that needs admin rights and, unlike
/// an assertion, **persists** until something flips it back. That persistence is
/// the danger: a Mac left awake with the lid shut can cook in a bag. So this
/// guard is deliberately blunt and defensive —
///   • engaged only while Taurine is awake, on AC power, and you asked for it
///   • reverted the instant any of those stops being true, and on quit
///   • idempotent: it prompts for admin only when the flag actually changes
///
/// We do not poll and we do not hold anything ourselves; the flag lives in the
/// kernel and we are careful to always put it back.
final class ClamshellGuard {
    /// Whether `disablesleep` is currently set *by us*.
    private(set) var active = false

    /// Drive the flag to `on`. No-op (and no prompt) if already there.
    /// Returns nil on success, or a human message if the admin step failed
    /// (most often: the user cancelled the password prompt).
    @discardableResult
    func set(_ on: Bool) -> String? {
        guard on != active else { return nil }
        if let err = run(disablesleep: on) { return err }
        active = on
        return nil
    }

    /// Best-effort revert with no prompt tolerance — used on quit.
    func revertQuietly() {
        guard active else { return }
        _ = run(disablesleep: false)
        active = false
    }

    /// Shell `pmset -a disablesleep 0|1` behind one admin authorization.
    /// AppleScript's `with administrator privileges` gives us the standard OS
    /// auth dialog and caches the grant briefly, so back-to-back flips within a
    /// few minutes don't re-prompt.
    private func run(disablesleep on: Bool) -> String? {
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(on ? 1 : 0)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        do { try p.run() } catch {
            return "Couldn't run pmset: \(error.localizedDescription)"
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // osascript -128 == user cancelled the auth dialog.
            if msg.contains("-128") || msg.contains("User canceled") {
                return "Cancelled — admin permission is required to keep the Mac awake with the lid closed."
            }
            return msg.isEmpty ? "pmset failed (exit \(p.terminationStatus))." : msg
        }
        return nil
    }

    deinit { revertQuietly() }
}
