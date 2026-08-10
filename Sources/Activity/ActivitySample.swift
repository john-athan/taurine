import Foundation

/// The readout. 📈
///
/// One instant of what the machine is doing, as plain value types. Nothing in
/// here talks to the kernel; the probes in `Sources/Activity/Probes` do that and
/// fill these in. Keeping the shape separate from the reading is what lets the
/// panel be written against a sample it can fabricate, and lets every probe be
/// swapped, skipped, or fail without the rest noticing.
///
/// Every section is optional on purpose. A Mac that cannot answer a question
/// (an Intel machine with no IOReport energy model, a service that refuses to
/// open) produces a sample with that section missing, and the panel simply
/// does not draw that tile. Taurine would rather show one fewer number than
/// invent one.
struct ActivitySample {

    /// Monotonic clock reading, from `ProcessInfo.systemUptime`. Wall time is
    /// deliberately not used: sampling must survive a clock change.
    var uptime: TimeInterval

    /// Seconds since the previous sample. Zero on the first sample of a run,
    /// which is the signal to every rate probe that it has no baseline yet and
    /// should report nothing rather than a number divided by zero.
    var interval: TimeInterval

    var cpu: CPUActivity?
    var gpu: GPUActivity?
    var memory: MemoryActivity?
    var disk: TrafficRate?
    var network: TrafficRate?
    var power: PowerActivity?
    var thermal: ThermalActivity?

    init(uptime: TimeInterval, interval: TimeInterval) {
        self.uptime = uptime
        self.interval = interval
    }
}

/// Which half of an Apple Silicon chip a core belongs to.
enum CoreKind {
    case efficiency
    case performance
}

/// How busy the processor is, per cluster and per core.
///
/// `cores` is busy fraction in `0...1`, in logical CPU order within the
/// cluster. `frequencyMHz` and `activeResidency` are filled by the IOReport
/// probe when it is available and stay nil otherwise, so the panel treats them
/// as a bonus rather than a promise.
struct CPUActivity {

    struct Cluster {
        let id: String
        let kind: CoreKind
        var cores: [Double]
        var frequencyMHz: Double?
        var activeResidency: Double?

        /// Mean busy fraction across the cluster's cores, in `0...1`.
        var busy: Double {
            guard !cores.isEmpty else { return 0 }
            return cores.reduce(0, +) / Double(cores.count)
        }
    }

    var clusters: [Cluster]

    /// Busy fraction across every logical core on the machine, in `0...1`.
    /// Weighted by core count, so four saturated efficiency cores on a
    /// fourteen-core chip read as 29%, not 50%.
    var busy: Double {
        let all = clusters.flatMap { $0.cores }
        guard !all.isEmpty else { return 0 }
        return all.reduce(0, +) / Double(all.count)
    }
}

/// Integrated GPU load. `utilization` is in `0...1`.
struct GPUActivity {
    var utilization: Double
    var frequencyMHz: Double?
}

/// Memory, in bytes, using the same accounting Activity Monitor shows.
///
/// `used` is app + wired + compressed, which is the number people recognise as
/// "Memory Used". `cached` is file-backed memory the kernel will hand back on
/// demand, and is deliberately excluded from `used` for that reason.
struct MemoryActivity {
    var used: UInt64
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64

    /// Fraction of physical memory in use, in `0...1`.
    var usedFraction: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }
}

/// A pair of byte counters and the rates derived from them.
///
/// Direction is named from the machine's point of view: for the network,
/// inbound is received and outbound is sent; for storage, inbound is read from
/// the device and outbound is written to it.
struct TrafficRate {
    var inboundBytesPerSecond: Double
    var outboundBytesPerSecond: Double
    var inboundTotal: UInt64
    var outboundTotal: UInt64
}

/// Instantaneous power draw, in watts, as reported by the chip's own energy
/// counters. Any field may be nil on a Mac that does not publish that counter.
struct PowerActivity {
    var cpuWatts: Double?
    var gpuWatts: Double?
    var aneWatts: Double?

    /// Everything the energy model attributes to the package. Not the same as
    /// wall draw: the display, the SSD and the fans are not in here.
    var packageWatts: Double?

    /// Sum of the parts that are known, for a single headline number.
    var totalWatts: Double? {
        if let packageWatts { return packageWatts }
        let parts = [cpuWatts, gpuWatts, aneWatts].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}

/// How close the machine is to throttling. Public API, free to read, and the
/// only heat signal Taurine reports: undocumented SMC temperature keys drift
/// between chip generations, and a wrong temperature is worse than none.
struct ThermalActivity {
    var state: ProcessInfo.ThermalState
}

