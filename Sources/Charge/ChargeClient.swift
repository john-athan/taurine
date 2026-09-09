import Foundation

/// The paperwork. 📋
///
/// Installing the root daemon is the only part of charge limiting that needs a
/// password, and it needs one exactly once. After that the menu writes a plain
/// file that the admin group can write, so picking a different limit is free.
///
/// We reuse the authorization route `ClamshellGuard` already uses: AppleScript's
/// `with administrator privileges`, which gives the standard OS dialog and needs
/// no helper bundle, no `SMJobBless`, and no paid Developer ID.
///
/// Two things here are deliberate and worth not undoing.
///
/// **The daemon runs a copy of the binary, not the one in your app bundle.**
/// `/Applications` is `drwxrwxr-x root:admin`, so any code already running as an
/// admin user can rewrite a binary in there with no prompt at all. Pointing a
/// root LaunchDaemon at that path would turn "runs as you" into "runs as root"
/// for free, which is a privilege boundary worth keeping. So we install a copy
/// into `/Library/PrivilegedHelperTools`, which is `root:wheel` with a
/// root-owned parent chain all the way to `/`.
///
/// **Paths are validated, not escaped.** Everything below is interpolated into a
/// shell command that executes as root. Rather than try to escape quoting
/// correctly through two layers (AppleScript string, then `sh`), we refuse any
/// path containing a character that could change the command's meaning.
enum Admin {

    /// Characters we are willing to interpolate into a root shell command.
    /// Single quotes, backslashes, `$`, backticks, semicolons and newlines are
    /// all absent on purpose.
    private static let safe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._- +")

    static func isShellSafe(_ path: String) -> Bool {
        !path.isEmpty && path.unicodeScalars.allSatisfy { safe.contains($0) }
    }

    /// Run a shell command as root behind one auth dialog.
    /// Returns nil on success, or a human-readable message.
    ///
    /// The command itself legitimately contains `;` and quotes, so it is not
    /// validated here; callers validate the *paths* they interpolate, which are
    /// the only attacker-influenced part. Backslash is escaped before the quote,
    /// or the escaping would eat itself.
    static func run(_ shell: String) -> String? {
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        do { try p.run() } catch {
            return "Couldn't run the installer: \(error.localizedDescription)"
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if msg.contains("-128") || msg.contains("User canceled") {
                return "Cancelled. Charge limiting needs a one-time admin approval to install its daemon."
            }
            return msg.isEmpty ? "Installer failed (exit \(p.terminationStatus))." : msg
        }
        return nil
    }
}

enum ChargeInstaller {

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: ChargePaths.daemonPlist)
            && FileManager.default.fileExists(atPath: ChargePaths.helper)
    }

    /// True when the app has been rebuilt since the helper copy was made, so the
    /// menu can offer to refresh it. `cp -p` preserves both size and mtime, so
    /// equality here means the two files came from the same build.
    static var isStale: Bool {
        guard isInstalled, let exe = Bundle.main.executablePath else { return false }
        let fm = FileManager.default
        guard let a = try? fm.attributesOfItem(atPath: exe),
              let b = try? fm.attributesOfItem(atPath: ChargePaths.helper) else { return false }
        let sizeA = a[.size] as? Int, sizeB = b[.size] as? Int
        let dateA = a[.modificationDate] as? Date, dateB = b[.modificationDate] as? Date
        return sizeA != sizeB || dateA != dateB
    }

    /// A directory to stage the daemon plist in, created by this call and
    /// readable only by this user.
    ///
    /// The root command in `install` copies the staged file into
    /// `/Library/LaunchDaemons`, so whoever controls it between the write and
    /// that copy decides which program root runs at boot. This used to be a
    /// fixed name in the shared temporary directory, which left that window open
    /// to anything else running as this user: wait for the file to appear, swap
    /// it, and the password typed for Taurine installs someone else's daemon.
    ///
    /// `withIntermediateDirectories: false` makes creation *fail* on a directory
    /// that already exists rather than adopt it, so this is exclusive creation
    /// and the unguessable name is a second line rather than the first.
    ///
    /// Separate from `install` so it can be tested without an admin prompt.
    static func makeStagingDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("taurine-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Install (or refresh) the privileged helper and its LaunchDaemon. One prompt.
    static func install() -> String? {
        guard let exe = Bundle.main.executablePath else {
            return "Couldn't locate the Taurine binary."
        }
        guard Admin.isShellSafe(exe) else {
            return "Taurine is installed at a path containing unusual characters:\n\n\(exe)\n\n"
                 + "Move it somewhere with a plainer name and try again. The installer refuses "
                 + "to interpolate this into a command that runs as root."
        }

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(ChargePaths.label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(ChargePaths.helper)</string>
            <string>--charge-daemon</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ProcessType</key><string>Background</string>
        </dict>
        </plist>
        """

        let stageDir: URL
        do { stageDir = try makeStagingDirectory() }
        catch { return "Couldn't stage the daemon: \(error.localizedDescription)" }
        defer { try? FileManager.default.removeItem(at: stageDir) }

        let staged = stageDir.appendingPathComponent("taurine-charge.plist").path
        guard Admin.isShellSafe(staged) else {
            return "Your temporary directory has an unusual path; can't stage the installer safely."
        }
        // `atomically` writes beside the target and renames, so it stays inside
        // the directory created above rather than passing through a shared one.
        do { try plist.write(toFile: staged, atomically: true, encoding: .utf8) }
        catch { return "Couldn't stage the daemon: \(error.localizedDescription)" }

        // Note the two different directories. `state` is written by root, so it
        // lives somewhere only root can write. `config/` is written by the menu,
        // so it is group-writable, and root never writes into it.
        let cmd = [
            "/usr/bin/install -d -o root -g wheel -m 755 '/Library/PrivilegedHelperTools'",
            // -p preserves mtime, which is what `isStale` compares against.
            "/usr/bin/install -p -o root -g wheel -m 755 '\(exe)' '\(ChargePaths.helper)'",
            "/usr/bin/install -d -o root -g wheel -m 755 '\(ChargePaths.dir)'",
            "/usr/bin/install -d -o root -g admin -m 775 '\(ChargePaths.configDir)'",
            "/usr/bin/install -o root -g wheel -m 644 '\(staged)' '\(ChargePaths.daemonPlist)'",
            "/bin/launchctl bootout system/\(ChargePaths.label) 2>/dev/null || true",
            "/bin/launchctl bootstrap system '\(ChargePaths.daemonPlist)'",
        ].joined(separator: "; ")

        if let err = Admin.run(cmd) { return err }
        return nil
    }

    /// Remove the daemon. We release the SMC bit *first*, while the helper still
    /// exists, because the inhibit bit lives in hardware and would otherwise
    /// outlive everything capable of clearing it.
    static func uninstall() -> String? {
        let cmd = [
            "'\(ChargePaths.helper)' --charge-unlock 2>/dev/null || true",
            "/bin/launchctl bootout system/\(ChargePaths.label) 2>/dev/null || true",
            "/bin/rm -f '\(ChargePaths.daemonPlist)'",
            "/bin/rm -f '\(ChargePaths.helper)'",
            "/bin/rm -rf '\(ChargePaths.dir)'",
        ].joined(separator: "; ")
        return Admin.run(cmd)
    }
}
