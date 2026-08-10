import Foundation

/// The tachometer. 🏎️
///
/// `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` is the only public way to see
/// each core separately, and it hands back exactly what the scheduler keeps: a
/// flat array of four tick counters per logical CPU, counted at 100 Hz. There
/// is no "how busy is this core" call anywhere in public API; there is only the
/// difference between two of these arrays, which is why this probe takes its
/// first reading in `open()` and has something to subtract from by the time the
/// panel asks.
///
/// Three traps sit in this one call.
///
///   • The array is allocated by the kernel in this task's address space and it
///     is the caller's job to hand it back with `vm_deallocate`. `free()` is
///     wrong, releasing nothing is a leak of a few hundred bytes per second for
///     as long as the panel is open, and the size to deallocate is the *count
///     the call returned* times the stride of `integer_t`, not the size of the
///     array you thought you asked for.
///
///   • The pointer is typed `integer_t`, which is signed, but the counters it
///     points at are `natural_t`, which is not. Read them as `Int32` and a core
///     with more than 2.1 billion ticks reads as a large negative number. They
///     are rebound to `natural_t` before anything looks at them.
///
///   • `mach_host_self()` adds a send right every time it is called. Calling it
///     once per tick leaks port rights slowly; the port is taken in `open()`
///     and deallocated in `close()`, with `deinit` covering a probe that was
///     dropped rather than closed.
///
/// Cores arrive in logical CPU order, which `CPUTopology` already knows how to
/// cut into clusters, so this probe measures and hands the shape question to
/// the type that owns it.
final class ProcessorProbe: ActivityProbe {

    let name = "processor"

    enum Failure: Error, CustomStringConvertible {
        case noHostPort
        case kernel(kern_return_t)

        var description: String {
            switch self {
            case .noHostPort:
                return "The host port could not be obtained."
            case .kernel(let code):
                return "host_processor_info failed (\(code))."
            }
        }
    }

    /// One logical CPU's four counters, in the order the kernel writes them.
    /// `natural_t` is 32 bits wide, so a counter rolls over after roughly 497
    /// days of that core being in one state. A roll-over is not reconstructed:
    /// it is detected, and the tick it lands in reports nothing, which costs one
    /// dropped frame every 497 days and no arithmetic anybody has to trust.
    struct CoreTicks: Equatable {
        var user: natural_t
        var system: natural_t
        var idle: natural_t
        var nice: natural_t
    }

    private var host: host_t = 0
    private var previous: [CoreTicks] = []

    // MARK: - lifecycle

    func open() throws {
        close()
        let port = mach_host_self()
        // MACH_PORT_NULL is zero. Spelled out rather than imported, because the
        // macro's Swift visibility has changed between toolchains.
        guard port != 0 else { throw Failure.noHostPort }
        host = port

        // The baseline, so the panel's first frame carries a real CPU reading
        // rather than an empty tile. `ActivityMonitor` starts its clock right
        // after this returns and takes the first sample a quarter of a second
        // later, which is the span these ticks will be measured over.
        var status: kern_return_t = KERN_SUCCESS
        guard let baseline = ticks(status: &status) else {
            close()
            throw Failure.kernel(status)
        }
        previous = baseline
    }

    func close() {
        if host != 0 {
            mach_port_deallocate(mach_task_self_, host)
            host = 0
        }
        previous = []
    }

    deinit {
        // The protocol puts the obligation on the probe, not on whoever holds
        // it. `ActivityMonitor` always closes, but a probe dropped by anything
        // else would otherwise leak a host send right per cycle.
        close()
    }

    func read(into sample: inout ActivitySample) {
        var status: kern_return_t = KERN_SUCCESS
        guard let current = ticks(status: &status) else { return }
        defer { previous = current }

        guard let cores = Self.busy(from: previous, to: current),
              let clusters = Self.clusters(from: cores, topology: CPUTopology.current)
        else { return }

        sample.cpu = CPUActivity(clusters: clusters)
    }

    // MARK: - the kernel call

    private func ticks(status: inout kern_return_t) -> [CoreTicks]? {
        guard host != 0 else { return nil }

        var cores: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0

        status = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cores, &info, &count)
        guard status == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        }

        let raw = info.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
            Array(UnsafeBufferPointer(start: $0, count: Int(count)))
        }
        return Self.decode(raw, cores: Int(cores))
    }

    // MARK: - the arithmetic

    /// Split the flat tick array into per-core readings. `cores` is what the
    /// kernel said; the array length is what it actually wrote, and the shorter
    /// of the two wins so a short read cannot walk off the end.
    static func decode(_ raw: [natural_t], cores: Int) -> [CoreTicks] {
        let states = Int(CPU_STATE_MAX)
        let n = min(cores, raw.count / states)
        guard n > 0 else { return [] }
        return (0..<n).map { core in
            let base = core * states
            return CoreTicks(user: raw[base + Int(CPU_STATE_USER)],
                             system: raw[base + Int(CPU_STATE_SYSTEM)],
                             idle: raw[base + Int(CPU_STATE_IDLE)],
                             nice: raw[base + Int(CPU_STATE_NICE)])
        }
    }

    /// Busy fraction per core, in `0...1`, from two readings of the tick array.
    ///
    /// Busy is everything that is not idle, which includes `nice`: work done at
    /// a low priority is still work, and a machine running a renice'd build at
    /// full tilt is not idle however politely it is doing it.
    ///
    /// Returns nil for the whole reading rather than for one core. A core whose
    /// counters moved backwards, a core count that changed under us, or an
    /// interval so short that no core accrued a tick are all cases where the
    /// array as a whole cannot be trusted, and a partly-real CPU graph is worse
    /// than a gap in one.
    static func busy(from previous: [CoreTicks], to current: [CoreTicks]) -> [Double]? {
        guard !previous.isEmpty, previous.count == current.count else { return nil }

        var fractions: [Double] = []
        fractions.reserveCapacity(current.count)

        for (was, now) in zip(previous, current) {
            // Backwards means one of these 32 bit counters rolled over, which
            // takes 497 days in one state. The reading is dropped rather than
            // reconstructed: one blank frame every 497 days is cheaper than
            // arithmetic that can only ever be tested against itself.
            guard now.user >= was.user, now.system >= was.system,
                  now.idle >= was.idle, now.nice >= was.nice else { return nil }

            let busy = UInt64(now.user - was.user)
                + UInt64(now.system - was.system)
                + UInt64(now.nice - was.nice)
            let idle = UInt64(now.idle - was.idle)
            let total = busy + idle
            guard total > 0 else { return nil }

            fractions.append(Double(busy) / Double(total))
        }
        return fractions
    }

    /// Deal per-core fractions into the chip's clusters.
    ///
    /// Refused outright when the counts disagree. That means an Intel Mac with
    /// hyperthreading disabled between readings, or a topology this probe
    /// cannot map onto, and dealing fourteen numbers into ten slots by dropping
    /// four of them would produce a plausible-looking lie.
    static func clusters(from cores: [Double], topology: CPUTopology) -> [CPUActivity.Cluster]? {
        guard !cores.isEmpty, cores.count == topology.coreCount else { return nil }
        guard let highest = topology.clusters.flatMap(\.coreIDs).max(), highest < cores.count else {
            return nil
        }
        return topology.clusters.map { cluster in
            CPUActivity.Cluster(id: cluster.id,
                                kind: cluster.kind,
                                cores: cluster.coreIDs.map { cores[$0] },
                                frequencyMHz: nil,
                                activeResidency: nil)
        }
    }
}
