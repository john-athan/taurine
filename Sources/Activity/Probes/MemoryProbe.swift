import Foundation

/// The inventory. 🧠
///
/// Memory is the number people are most likely to have a second opinion about,
/// because Activity Monitor is open on the next Space. So this probe reproduces
/// Activity Monitor's accounting exactly rather than inventing a defensible one
/// of its own, and the accounting is not what the field names suggest.
///
/// `vm_statistics64` offers a dozen page counts and almost none of them mean
/// what a reader expects. "Memory Used" is *not* physical minus free: on a Mac
/// with healthy caching, free is a rounding error and that subtraction reads
/// 99% forever. It is three specific buckets added together:
///
///   • **App memory**, anonymous pages that belong to processes, which is
///     `internal_page_count` minus `purgeable_count`. Purgeable pages are
///     anonymous but the kernel is allowed to throw them away, so they are not
///     a claim on memory.
///   • **Wired**, `wire_count`, which nobody can reclaim.
///   • **Compressed**, `compressor_page_count`, the resident size of the
///     compressor pool. On a machine under pressure this is the largest of the
///     three, and leaving it out is the usual reason a home-made memory readout
///     disagrees with Activity Monitor by many gigabytes.
///
/// Everything else, file-backed pages plus the purgeable ones, is cache: the
/// kernel hands it back the moment anybody wants it, so counting it as used
/// would make every well-behaved Mac look full.
///
/// The trap in the arithmetic is that `internal_page_count` and
/// `purgeable_count` are not sampled at the same instant inside the kernel, so
/// purgeable can briefly exceed internal. On `UInt64` that subtraction wraps to
/// sixteen exabytes of app memory, which is why it floors at zero here.
///
/// Totals come from `hw.memsize` rather than from summing the page counts. The
/// buckets do not add up to physical memory on Apple Silicon, because firmware
/// and the display carve out DRAM that never appears in any of them, and a
/// total derived from the parts would silently shrink.
final class MemoryProbe: ActivityProbe {

    let name = "memory"

    enum Failure: Error, CustomStringConvertible {
        case noHostPort
        case noPhysicalMemory
        case kernel(kern_return_t)

        var description: String {
            switch self {
            case .noHostPort:      return "The host port could not be obtained."
            case .noPhysicalMemory: return "hw.memsize did not answer."
            case .kernel(let code): return "host_statistics64 failed (\(code))."
            }
        }
    }

    /// The five page counts the accounting needs, pulled out of
    /// `vm_statistics64` so the arithmetic can be tested without a kernel.
    struct PageCounts {
        var wired: UInt64
        var internalPages: UInt64
        var external: UInt64
        var purgeable: UInt64
        var compressed: UInt64
    }

    private var host: host_t = 0
    /// Physical memory does not change while a process lives, so it is read
    /// when the panel opens and dropped when it closes. Cached for the session,
    /// not across sessions, which is what the lifecycle contract asks for.
    private var physical: UInt64 = 0

    // MARK: - lifecycle

    func open() throws {
        close()
        let port = mach_host_self()
        guard port != 0 else { throw Failure.noHostPort }
        host = port

        // `CPUTopology.sysctlInt` is the app's one sysctl helper, already
        // handling the 32-versus-64-bit key widths. Borrowing it beats a second
        // copy of that logic living here.
        guard let bytes = CPUTopology.sysctlInt("hw.memsize"), bytes > 0 else {
            close()
            throw Failure.noPhysicalMemory
        }
        physical = UInt64(bytes)

        var status: kern_return_t = KERN_SUCCESS
        if pages(status: &status) == nil {
            close()
            throw Failure.kernel(status)
        }
    }

    func close() {
        if host != 0 {
            mach_port_deallocate(mach_task_self_, host)
            host = 0
        }
        physical = 0
    }

    deinit {
        // The protocol puts the obligation on the probe. A dropped but unclosed
        // MemoryProbe would otherwise leak a host send right.
        close()
    }

    func read(into sample: inout ActivitySample) {
        // A level, not a rate: nothing here is measured against a previous
        // reading, so there is no baseline for `open()` to take.
        var status: kern_return_t = KERN_SUCCESS
        guard let counts = pages(status: &status), physical > 0 else { return }
        let swap = Self.swapUsage()
        sample.memory = Self.account(counts,
                                     pageSize: UInt64(vm_kernel_page_size),
                                     physical: physical,
                                     swapUsed: swap.used,
                                     swapTotal: swap.total)
    }

    // MARK: - the kernel calls

    /// Internal rather than private so a test can hold the five counts up
    /// against `vm_stat`, which is the only way the field-to-field mapping
    /// below is checkable at all.
    func pages(status: inout kern_return_t) -> PageCounts? {
        guard host != 0 else { return nil }

        var stats = vm_statistics64_data_t()
        // The call counts in `integer_t` words, not bytes, and passing the byte
        // size instead is the classic way to get KERN_INVALID_ARGUMENT here.
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        return PageCounts(wired: UInt64(stats.wire_count),
                          internalPages: UInt64(stats.internal_page_count),
                          external: UInt64(stats.external_page_count),
                          purgeable: UInt64(stats.purgeable_count),
                          compressed: UInt64(stats.compressor_page_count))
    }

    /// `vm.swapusage` answers with a fixed C struct, and a Mac with swap
    /// disabled answers with zeroes rather than failing, which is the correct
    /// reading: no swap file is not the same as no answer.
    static func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0,
              size == MemoryLayout<xsw_usage>.size else { return (0, 0) }
        return (UInt64(usage.xsu_used), UInt64(usage.xsu_total))
    }

    // MARK: - the accounting

    /// Page counts in, bytes out, in Activity Monitor's own buckets.
    static func account(_ pages: PageCounts, pageSize: UInt64, physical: UInt64,
                        swapUsed: UInt64, swapTotal: UInt64) -> MemoryActivity {
        // Saturating, because the two counters are sampled a few instructions
        // apart inside the kernel and the difference can go the wrong way.
        let appPages = pages.internalPages > pages.purgeable
            ? pages.internalPages - pages.purgeable : 0

        let app = appPages * pageSize
        let wired = pages.wired * pageSize
        let compressed = pages.compressed * pageSize

        return MemoryActivity(used: app + wired + compressed,
                              total: physical,
                              app: app,
                              wired: wired,
                              compressed: compressed,
                              cached: (pages.external + pages.purgeable) * pageSize,
                              swapUsed: swapUsed,
                              swapTotal: swapTotal)
    }
}
