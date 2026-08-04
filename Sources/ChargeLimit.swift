import Foundation

/// The governor. 🎚️
///
/// Two layers live here. `ChargeGovernor` knows which SMC keys this particular
/// Mac speaks and how to say "stop charging" in that dialect. `ChargeConfig`
/// and `ChargeState` are the two little files the menu bar app and the root
/// daemon use to talk past the privilege boundary.
///
/// The key dialect matters more than it looks. Apple silicon before macOS 26
/// used `CH0B`; a contributor to AlDente found that `CH0C` also has to be set,
/// because with `CH0B` alone charging can quietly resume during sleep. macOS 26
/// replaced both with a four-byte `CHTE`, and on machines that have `CHTE` the
/// old keys are simply absent. So we probe rather than guess, which is why this
/// file never mentions a macOS version number.
enum ChargeKey {
    /// macOS 26+. Four bytes: 01 00 00 00 inhibits, 00 00 00 00 permits.
    static let tahoe   = "CHTE"
    /// Pre-26. One byte: 0x02 inhibits, 0x00 permits.
    static let legacyB = "CH0B"
    /// The sleep-resume partner to CH0B. Absent on some models, so best effort.
    static let legacyC = "CH0C"
}

/// Which set of keys this Mac actually has.
enum ChargePath: String {
    case tahoe        = "CHTE"
    case legacy       = "CH0B+CH0C"
    case unsupported  = "none"

    var isSupported: Bool { self != .unsupported }
}

final class ChargeGovernor {
    let path: ChargePath
    private let smc: SMC

    init(smc: SMC) {
        self.smc = smc
        if smc.has(ChargeKey.tahoe)        { path = .tahoe }
        else if smc.has(ChargeKey.legacyB) { path = .legacy }
        else                               { path = .unsupported }
    }

    /// Is the adapter currently permitted to charge the cell? We read this back
    /// from the SMC rather than trusting a cached flag, because firmware, a
    /// crashed predecessor, or another charge limiter may have moved it.
    var chargingPermitted: Bool? {
        switch path {
        case .tahoe:
            guard let v = try? smc.read(ChargeKey.tahoe) else { return nil }
            return v.allSatisfy { $0 == 0 }
        case .legacy:
            guard let v = try? smc.read(ChargeKey.legacyB), let b = v.first else { return nil }
            return b == 0
        case .unsupported:
            return nil
        }
    }

    /// Permit or inhibit charging. Returns nil on success, or a message to show.
    @discardableResult
    func setCharging(permitted: Bool) -> String? {
        do {
            switch path {
            case .tahoe:
                try smc.write(ChargeKey.tahoe, permitted ? [0, 0, 0, 0] : [1, 0, 0, 0])

            case .legacy:
                let v: UInt8 = permitted ? 0x00 : 0x02
                try smc.write(ChargeKey.legacyB, [v])
                // Best effort: absent on some models, and CH0B alone is enough
                // to be correct while awake. CH0C is the belt for sleep.
                try? smc.write(ChargeKey.legacyC, [v])

            case .unsupported:
                return "This Mac exposes neither CHTE nor CH0B, so charge limiting is not available."
            }
            return nil
        } catch {
            return "\(error)"
        }
    }
}

// MARK: - the privilege boundary

/// Where the GUI and the daemon meet: two plain text files, deliberately in two
/// different directories.
///
/// `config/` is group-writable so the menu can change the limit without a
/// password. `state` is written by root, so it lives one level up in a directory
/// only root can write. Root never writes into a directory the admin group
/// controls, which keeps a planted symlink or a swapped file out of the picture.
///
/// Any admin user can therefore set the charge limit. That grants nobody
/// anything new (an admin can `sudo` regardless), the daemon clamps whatever it
/// reads to `ChargeConfig.range`, and the worst case is a mildly annoying
/// battery ceiling.
enum ChargePaths {
    static let label       = "io.github.john-athan.taurine.charge"
    static let dir         = "/Library/Application Support/Taurine"   // root:wheel 755
    static let configDir   = dir + "/config"                          // root:admin 775
    static let limit       = configDir + "/limit"
    static let state       = dir + "/state"                           // root writes, all read
    static let daemonPlist = "/Library/LaunchDaemons/\(label).plist"
    /// Root-owned copy of the binary that launchd actually executes.
    /// Not the one in /Applications; see `ChargeInstaller`.
    static let helper      = "/Library/PrivilegedHelperTools/\(label)"
}

enum ChargeConfig {
    /// Sane bounds. Below 20 the Mac is unpleasant to use; 100 means "off".
    static let range = 20...95

    /// Desired limit, or nil for "don't limit anything".
    static func read() -> Int? {
        guard let raw = try? String(contentsOfFile: ChargePaths.limit, encoding: .utf8) else { return nil }
        guard let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        guard range.contains(n) else { return nil }
        return n
    }

    /// Write the desired limit. nil turns limiting off. Returns an error message
    /// on failure, which in practice means the daemon was never installed.
    static func write(_ limit: Int?) -> String? {
        let text = limit.map(String.init) ?? "off"
        do {
            try text.write(toFile: ChargePaths.limit, atomically: true, encoding: .utf8)
            // Atomic writes land as a fresh file owned by us; keep the group able
            // to rewrite it so a second admin account isn't locked out.
            try? FileManager.default.setAttributes([.posixPermissions: 0o664],
                                                   ofItemAtPath: ChargePaths.limit)
            return nil
        } catch {
            return "Couldn't write \(ChargePaths.limit): \(error.localizedDescription)"
        }
    }
}

/// What the daemon last did, for the menu to display. Read on demand when a
/// menu opens, never watched, never polled.
struct ChargeState {
    var limit: Int?
    var percent: Int?
    var permitted: Bool?
    var path: ChargePath
    var onAC: Bool

    static func read() -> ChargeState? {
        guard let raw = try? String(contentsOfFile: ChargePaths.state, encoding: .utf8) else { return nil }
        var kv: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { kv[String(parts[0])] = String(parts[1]) }
        }
        return ChargeState(
            limit: kv["limit"].flatMap(Int.init),
            percent: kv["percent"].flatMap(Int.init),
            permitted: kv["permitted"].map { $0 == "1" },
            path: kv["path"].flatMap(ChargePath.init(rawValue:)) ?? .unsupported,
            onAC: kv["ac"] == "1")
    }

    func serialized() -> String {
        var lines = ["path=\(path.rawValue)", "ac=\(onAC ? 1 : 0)"]
        if let limit { lines.append("limit=\(limit)") }
        if let percent { lines.append("percent=\(percent)") }
        if let permitted { lines.append("permitted=\(permitted ? 1 : 0)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One line for the menu bar header.
    var summary: String {
        guard path.isSupported else { return "not supported on this Mac" }
        guard let limit else { return "off, charging to 100%" }
        guard let percent else { return "limit \(limit)%" }
        if permitted == false { return "holding at \(percent)%, limit \(limit)%" }
        return onAC ? "charging \(percent)% → \(limit)%" : "on battery, \(percent)%"
    }
}
