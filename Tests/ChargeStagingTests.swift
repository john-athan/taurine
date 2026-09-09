import Foundation

/// The two guards standing between a file on this machine and a command that
/// runs as root. 🔐
///
/// `ChargeInstaller.install` builds one shell command and hands it to
/// `osascript … with administrator privileges`. Everything it interpolates is a
/// path, and everything it copies is a file, so the whole safety of that step
/// rests on two much smaller questions: can a path change the meaning of the
/// command, and can anything else on the machine substitute the file being
/// copied. Neither can be asked of `install` itself without an admin dialog, so
/// both are asked of the pieces it is built from.
func runChargeStagingTests() {

    Check.suite("staging: each install gets a directory of its own") {
        guard let a = try? ChargeInstaller.makeStagingDirectory() else {
            Check.that(false, "a staging directory was created")
            return
        }
        defer { try? FileManager.default.removeItem(at: a) }

        guard let b = try? ChargeInstaller.makeStagingDirectory() else {
            Check.that(false, "a second staging directory was created")
            return
        }
        defer { try? FileManager.default.removeItem(at: b) }

        Check.that(a.path != b.path, "two calls never land on the same path")
        Check.that(a.path.hasPrefix(NSTemporaryDirectory()), "inside the user's temporary directory")
    }

    Check.suite("staging: nobody else can reach into it") {
        guard let dir = try? ChargeInstaller.makeStagingDirectory() else {
            Check.that(false, "a staging directory was created")
            return
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path)
        let mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        Check.equal(mode, 0o700, "owner only, no group and no other")
    }

    Check.suite("staging: an existing directory is refused, not adopted") {
        // The property that closes the swap window. If creation adopted a
        // directory that was already there, an attacker who guessed the name
        // could pre-create it, keep write access, and replace the plist between
        // the write and the root copy. Exclusive creation is what makes the
        // unguessable name a second line of defence rather than the only one.
        guard let dir = try? ChargeInstaller.makeStagingDirectory() else {
            Check.that(false, "a staging directory was created")
            return
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        var adopted = false
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            adopted = true
        } catch {
            adopted = false
        }
        Check.that(!adopted, "creating over an existing directory throws")
    }

    Check.suite("staging: the path is safe to interpolate into the root command") {
        guard let dir = try? ChargeInstaller.makeStagingDirectory() else {
            Check.that(false, "a staging directory was created")
            return
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let staged = dir.appendingPathComponent("taurine-charge.plist").path
        Check.that(Admin.isShellSafe(staged), "the generated name passes the same guard install uses")
    }

    Check.suite("paths: a character that could change the command is refused") {
        // These are the ones that matter through two layers, AppleScript's string
        // and then sh: a quote ends the argument, a semicolon starts a second
        // command, a backtick or $( ) substitutes one, a backslash escapes the
        // escaping, and a newline is a command separator all by itself.
        for hostile in ["/tmp/a'b", "/tmp/a;rm -rf /", "/tmp/a`id`", "/tmp/a$(id)",
                        "/tmp/a\\b", "/tmp/a\nb", "/tmp/a\"b", "/tmp/a|b", "/tmp/a&b"] {
            Check.that(!Admin.isShellSafe(hostile), "refused: \(hostile.debugDescription)")
        }
        Check.that(!Admin.isShellSafe(""), "an empty path is not a path")
    }

    Check.suite("paths: an ordinary install location still passes") {
        for fine in ["/Applications/Taurine.app/Contents/MacOS/taurine",
                     "/Users/someone/Applications/Taurine.app/Contents/MacOS/taurine",
                     "/Volumes/Macintosh HD/Applications/Taurine.app/Contents/MacOS/taurine",
                     "/Library/PrivilegedHelperTools/io.github.john-athan.taurine.charge"] {
            Check.that(Admin.isShellSafe(fine), "accepted: \(fine)")
        }
    }

    Check.suite("config: the daemon only ever reads a limit inside its range") {
        // The config file is group-writable so a second admin account can change
        // the limit without a password. Whatever is in it is read by a process
        // running as root, so the range check is the boundary.
        for bad in ["0", "19", "96", "100", "-5", "not a number", "", "50; rm -rf /"] {
            Check.that(ChargeConfig.parse(bad) == nil, "refused: \(bad.debugDescription)")
        }
        Check.equal(ChargeConfig.parse("20"), 20, "the bottom of the range")
        Check.equal(ChargeConfig.parse("95"), 95, "the top of the range")
        Check.equal(ChargeConfig.parse(" 80\n"), 80, "surrounding whitespace is trimmed")
    }
}
