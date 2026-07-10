import Foundation

/// The truth serum. 🔎
///
/// macOS already knows exactly which process is keeping your Mac awake — it's
/// just buried in `pmset -g assertions`. No toggle app surfaces it. Taurine
/// does: this parses that output into a tidy list you can read in the menu.
/// "Why is my Mac awake?" — finally answerable.
enum AssertionInspector {

    struct Holder {
        let pid: Int
        let process: String
        let type: String       // e.g. PreventUserIdleDisplaySleep
        let name: String       // human reason the app supplied
        let timeout: String?   // "fires in Ns", if any

        /// A short, human phrasing for a menu row.
        var line: String {
            let t = type
                .replacingOccurrences(of: "PreventUserIdle", with: "")
                .replacingOccurrences(of: "Prevent", with: "")
                .replacingOccurrences(of: "Sleep", with: "")   // Display / System / …
            return "\(process) — keeps \(t.isEmpty ? "awake" : t) awake"
        }
    }

    /// Snapshot the current herd of assertion-holders. Runs `pmset` on demand
    /// (only when the user opens the menu) so idle cost stays zero.
    static func current() -> [Holder] {
        guard let raw = run("/usr/bin/pmset", ["-g", "assertions"]) else { return [] }
        return parse(raw)
    }

    /// Exposed for the CLI `taurine why` command and for tests.
    static func parse(_ raw: String) -> [Holder] {
        var holders: [Holder] = []
        // Lines look like:
        //   pid 4242(taurine): [0x…] 00:01:50 PreventUserIdleDisplaySleep named: "…"
        let pattern = #"pid (\d+)\(([^)]+)\):\s*\[[^\]]*\]\s*[\d:]+\s*(\w+)\s*named:\s*"([^"]*)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }

        let lines = raw.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let r = NSRange(line.startIndex..., in: line)
            guard let m = re.firstMatch(in: line, range: r) else { continue }
            func g(_ n: Int) -> String {
                guard let rr = Range(m.range(at: n), in: line) else { return "" }
                return String(line[rr])
            }
            // A "Timeout will fire in N secs" note may sit on the next line.
            var timeout: String? = nil
            if i + 1 < lines.count, lines[i + 1].contains("Timeout will fire") {
                timeout = lines[i + 1].trimmingCharacters(in: .whitespaces)
            }
            holders.append(Holder(pid: Int(g(1)) ?? 0, process: g(2),
                                  type: g(3), name: g(4), timeout: timeout))
        }
        return holders
    }

    // MARK: - tiny process runner (no shell, no injection surface)
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
