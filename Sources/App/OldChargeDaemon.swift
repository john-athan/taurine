import Foundation

/// The leftover.
///
/// Taurine used to limit charging itself: a root LaunchDaemon writing an
/// undocumented SMC key. macOS 27 ships a charge limit in System Settings, and
/// its powerd owns that key now, so the old daemon only crash-loops. The daemon
/// is gone (ADR 11); this removes what an older install left on disk, because
/// launchd would otherwise start it again at every boot.
enum OldChargeDaemon {
    static let label  = "io.github.john-athan.taurine.charge"
    static let plist  = "/Library/LaunchDaemons/\(label).plist"
    static let helper = "/Library/PrivilegedHelperTools/\(label)"
    static let dir    = "/Library/Application Support/Taurine"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plist) || FileManager.default.fileExists(atPath: helper)
    }

    /// One admin prompt. The old helper releases the SMC inhibit bit first, while
    /// it still exists, since that bit outlives every process able to clear it.
    /// Nothing here is interpolated from outside, so there is nothing to escape.
    static func remove() -> String? {
        let cmd = [
            "'\(helper)' --charge-unlock >/dev/null 2>&1 || true",
            "/bin/launchctl bootout system/\(label) 2>/dev/null || true",
            "/bin/rm -f '\(plist)' '\(helper)'",
            "/bin/rm -rf '\(dir)'",
        ].joined(separator: "; ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(cmd)\" with administrator privileges"]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        do { try p.run() } catch { return "Couldn't run the cleanup: \(error.localizedDescription)" }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if msg.contains("-128") || msg.contains("User canceled") { return nil }
            return msg.isEmpty ? "Cleanup failed (exit \(p.terminationStatus))." : msg
        }
        return nil
    }
}
