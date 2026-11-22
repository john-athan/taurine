import Foundation

/// The only outward sign that an event tap exists.
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
