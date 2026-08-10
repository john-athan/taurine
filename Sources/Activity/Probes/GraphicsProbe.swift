import Foundation
import IOKit

/// The gauge. 🎮
///
/// The GPU is the one number in this panel that the kernel already computes for
/// us. Every accelerator publishes a `PerformanceStatistics` dictionary in the
/// IO registry, and `"Device Utilization %"` in it is the driver's own busy
/// figure over its last internal window, as an integer percentage. `iStat` and
/// `Activity Monitor`'s GPU history read the same property.
///
/// Because it is a level and not a counter, this probe answers on the first
/// sample of a session, where the CPU, disk and network tiles are still blank.
/// That asymmetry is deliberate and is the whole point of `interval == 0`
/// meaning "no baseline": a level needs no history, a rate does.
///
/// Two decisions worth stating.
///
///   • The service is matched on `IOAccelerator`, not on a concrete driver
///     class. This Mac answers with `AGXAcceleratorG16X`; an Intel Mac answers
///     with `IntelAccelerator` and possibly an `AMDRadeonAccelerator` beside
///     it. Matching the family means the probe does not carry a list of chip
///     names that goes stale every autumn.
///
///   • When more than one accelerator answers, the highest utilisation wins
///     rather than the mean. A Mac with an idle integrated GPU and a saturated
///     discrete one is at 100% of the thing doing the work, and averaging it
///     down to 50% would describe neither piece of hardware.
///
/// The trap is the percentage itself: it is the driver's average over a window
/// that is not our sampling interval, and it occasionally reports above 100
/// when those windows straddle. It is clamped rather than trusted, because a
/// bar chart that runs off its own axis is a bug report waiting to happen.
final class GraphicsProbe: ActivityProbe {

    let name = "graphics"

    enum Failure: Error, CustomStringConvertible {
        case noAccelerator(kern_return_t)

        var description: String {
            switch self {
            case .noAccelerator(let code):
                return "No IOAccelerator service could be matched (\(code))."
            }
        }
    }

    private enum Key {
        static let statistics = "PerformanceStatistics"
        static let utilization = "Device Utilization %"
    }

    /// Held open for the session. Unlike block storage, accelerators do not
    /// come and go: an integrated GPU is soldered on, and external GPUs are not
    /// a thing on Apple Silicon. Holding the service saves a registry search
    /// every second, and if a card did disappear its property fetch would start
    /// returning nil, which this probe already treats as "no answer".
    private var accelerators: [io_service_t] = []

    // MARK: - lifecycle

    func open() throws {
        close()

        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault,
                                                  IOServiceMatching("IOAccelerator"),
                                                  &iterator)
        guard status == KERN_SUCCESS, iterator != IO_OBJECT_NULL else {
            throw Failure.noAccelerator(status)
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            accelerators.append(service)   // ownership moves into the array
            service = IOIteratorNext(iterator)
        }

        guard !accelerators.isEmpty else { throw Failure.noAccelerator(status) }
    }

    func close() {
        for service in accelerators { IOObjectRelease(service) }
        accelerators = []
    }

    func read(into sample: inout ActivitySample) {
        var busiest: Double?
        for service in accelerators {
            guard let percent = Self.utilizationPercent(of: service) else { continue }
            let value = Self.utilization(fromPercent: percent)
            busiest = max(busiest ?? value, value)
        }
        guard let busiest else { return }
        // frequencyMHz stays nil: it comes from IOReport's state residency
        // counters, which are a different probe's business entirely.
        sample.gpu = GPUActivity(utilization: busiest, frequencyMHz: nil)
    }

    // MARK: - the registry

    private static func utilizationPercent(of service: io_service_t) -> Int? {
        guard let property = IORegistryEntryCreateCFProperty(service,
                                                             Key.statistics as CFString,
                                                             kCFAllocatorDefault, 0),
              let stats = property.takeRetainedValue() as? [String: Any],
              let value = stats[Key.utilization] as? NSNumber else { return nil }
        return value.intValue
    }

    /// A driver percentage turned into the `0...1` fraction the sample carries.
    static func utilization(fromPercent percent: Int) -> Double {
        min(1, max(0, Double(percent) / 100))
    }
}
