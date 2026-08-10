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

/// The only outward sign that an event tap exists. 🧵
///
/// A tap is a port, a run loop and a thread, and of those only the thread has a
/// name this process can read back. So "is a tap armed", "did starting twice arm
/// two of them" and "did stopping really stop it" are all asked here, by
/// identity rather than by count: a `start()` that tore a tap down and rebuilt it
/// would keep the count at one and still be wrong.
///
/// Kernel thread ids, not mach port names: a port name can be recycled, a thread
/// id never is, so a rebuilt tap thread is always distinguishable from a kept
/// one.
enum TapThreads {

    /// The ids of every live thread whose name contains `fragment`. Tap threads
    /// are named after their feature (`taurine.scroll`, `taurine.finder`).
    static func live(named fragment: String) -> Set<UInt64> {
        var ports: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &ports, &count) == KERN_SUCCESS, let ports else { return [] }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, ports[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: ports)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
        }

        var found: Set<UInt64> = []
        for i in 0..<Int(count) where name(of: ports[i]).contains(fragment) {
            if let id = identifier(of: ports[i]) { found.insert(id) }
        }
        return found
    }

    /// The name `Thread.name` put on the underlying pthread, or "" if it has none.
    private static func name(of port: thread_act_t) -> String {
        var info = thread_extended_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size
                                          / MemoryLayout<natural_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                thread_info(port, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &size)
            }
        }
        guard ok == KERN_SUCCESS else { return "" }
        return withUnsafeBytes(of: &info.pth_name) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    /// The kernel's unique id for a thread.
    private static func identifier(of port: thread_act_t) -> UInt64? {
        var info = thread_identifier_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size
                                          / MemoryLayout<natural_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                thread_info(port, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &size)
            }
        }
        return ok == KERN_SUCCESS ? info.thread_id : nil
    }
}
