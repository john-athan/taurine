import Foundation

/// The lab bench.
///
/// The Swift apps in this fleet build with `swiftc` and nothing else: no Xcode
/// project, no SwiftPM, no package resolution, no network. A test framework
/// that demanded any of those would cost more than it is worth, so this is the
/// whole thing: a counter, a failure list, and an exit code.
///
/// Tests live in `Tests/*.swift`, one file per subsystem, each exposing a
/// `func run<Something>Tests()`. `tools/test.sh` discovers those by name,
/// generates the entry point and compiles this file in, so adding a test file
/// requires editing no registry.
///
/// Owned by oss-kit (templates/shared/swift). Change it there, then
/// `oss sync-tooling`; a copy edited here is reported by `oss doctor`.
enum Check {

    private(set) static var checks = 0
    private(set) static var failures: [String] = []
    private(set) static var skipped: [String] = []
    private static var suite = "(no suite)"

    /// Whether this process is running inside a virtual machine.
    ///
    /// Some suites ask the machine about itself rather than about the app:
    /// power counters, voltage tables, a GPU. A virtual machine has none of
    /// that. `kern.hv_vmm_present` is the kernel's own answer and is 1 under
    /// any hypervisor, GitHub's macOS runners included.
    static let isVirtual: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }()

    /// A suite that only real hardware can answer. On a virtual machine it is
    /// recorded as skipped and never run, so a red run means the app is wrong
    /// rather than that the runner is not a Mac.
    static func hardwareSuite(_ name: String, _ body: () -> Void) {
        guard !isVirtual else {
            skipped.append(name)
            return
        }
        suite(name, body)
    }

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
        if !skipped.isEmpty {
            print("⊘ \(skipped.count) suite(s) skipped: this is a virtual machine, "
                  + "and they ask questions only hardware can answer")
            for s in skipped { print("   • \(s)") }
            print("")
        }
        if failures.isEmpty {
            print("✅ \(checks) checks passed")
            return 0
        }
        print("❌ \(failures.count) of \(checks) checks failed\n")
        for f in failures { print("   • \(f)") }
        return 1
    }
}
