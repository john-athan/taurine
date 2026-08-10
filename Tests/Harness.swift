import Foundation

/// The lab bench. 🧪
///
/// Taurine builds with `swiftc` and nothing else: no Xcode project, no SwiftPM,
/// no package resolution, no network. A test framework that demanded any of
/// those would cost more than it is worth, so this is the whole thing: a
/// counter, a failure list, and an exit code.
///
/// Tests live in `Tests/*.swift`, one file per subsystem, each exposing a
/// `func run<Something>Tests()`. `tests/run.sh` discovers those by name and
/// generates the entry point, so adding a test file requires editing no
/// registry, which also means two people can add test files at the same time
/// without touching the same line.
enum Check {

    private(set) static var checks = 0
    private(set) static var failures: [String] = []
    private static var suite = "(no suite)"

    /// Group a handful of related checks under a name, for readable output.
    static func suite(_ name: String, _ body: () -> Void) {
        let previous = suite
        suite = name
        body()
        suite = previous
    }

    /// The primitive. Everything else funnels through here.
    static func that(_ condition: Bool, _ what: String,
                     file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        guard !condition else { return }
        failures.append("\(suite): \(what)\n      at \(file):\(line)")
    }

    static func equal<T: Equatable>(_ got: T, _ want: T, _ what: String,
                                    file: StaticString = #fileID, line: UInt = #line) {
        that(got == want, "\(what) (got \(got), want \(want))", file: file, line: line)
    }

    /// Floating-point comparison with an explicit tolerance. There is no
    /// default tolerance on purpose: a number's acceptable slop is a property
    /// of what it measures, not of the test framework.
    static func close(_ got: Double, _ want: Double, tolerance: Double, _ what: String,
                      file: StaticString = #fileID, line: UInt = #line) {
        that(abs(got - want) <= tolerance,
             "\(what) (got \(got), want \(want) ±\(tolerance))", file: file, line: line)
    }

    static func isNil<T>(_ got: T?, _ what: String,
                         file: StaticString = #fileID, line: UInt = #line) {
        that(got == nil, "\(what) (expected nil, got \(String(describing: got)))",
             file: file, line: line)
    }

    /// Unwrap or fail, so one missing value does not take the whole run down.
    @discardableResult
    static func unwrap<T>(_ got: T?, _ what: String,
                          file: StaticString = #fileID, line: UInt = #line) -> T? {
        that(got != nil, "\(what) (expected a value, got nil)", file: file, line: line)
        return got
    }

    static func throwsError(_ what: String, _ body: () throws -> Void,
                            file: StaticString = #fileID, line: UInt = #line) {
        do {
            try body()
            that(false, "\(what) (expected a thrown error, none thrown)", file: file, line: line)
        } catch {
            that(true, what, file: file, line: line)
        }
    }

    /// Print the tally and hand back a process exit code.
    static func report() -> Int32 {
        if failures.isEmpty {
            print("✅ \(checks) checks passed")
            return 0
        }
        print("❌ \(failures.count) of \(checks) checks failed\n")
        for f in failures { print("   • \(f)") }
        return 1
    }
}
