import Foundation
import Darwin

/// The receipts. 📊
///
/// Every caffeine app claims to be "lightweight." Taurine *measures* its own
/// footprint instead of asserting it — every number in the menu badge is read
/// live from the kernel, not hard-coded:
///   • resident memory via `task_info`
///   • open BSD sockets via `proc_pidinfo` (libproc)
///   • active timers straight from the intent engine
///
/// The efficiency is architectural: assertions are passive kernel flags, and
/// every watcher is event-driven (process-exit sources, power-source
/// notifications, a Carbon hotkey), so while idle those counts are genuinely 0.
enum Diagnostics {

    /// Resident memory of *this* process, in megabytes.
    static var residentMemoryMB: Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }

    /// BSD sockets this process currently holds open, counted from the kernel's
    /// file-descriptor table. (AppKit and our IPC use mach ports, not sockets,
    /// so in normal operation this really is 0 — and now you can verify it.)
    static var openSocketCount: Int {
        let pid = getpid()
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return 0 }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let ret = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, size) }
        guard ret > 0 else { return 0 }
        let n = Int(ret) / MemoryLayout<proc_fdinfo>.stride
        return (0..<n).reduce(0) { $0 + (fds[$1].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) ? 1 : 0) }
    }

    /// Live one-line badge for the menu, e.g. "12.4 MB · 0 timers · 0 sockets".
    /// `activeTimers` is the number of live dispatch sources in the intent engine.
    static func badge(activeTimers: Int) -> String {
        let timers = activeTimers == 1 ? "1 timer" : "\(activeTimers) timers"
        let sockets = openSocketCount == 1 ? "1 socket" : "\(openSocketCount) sockets"
        return String(format: "%.1f MB · %@ · %@", residentMemoryMB, timers, sockets)
    }
}
