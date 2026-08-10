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
/// Because it is a level and not a counter, this probe has no baseline to take
/// in `open()`: the driver's window is the driver's business, and asking twice
/// would not make the answer better.
///
/// Two decisions worth stating.
///
///   • The service is matched on `IOAccelerator`, not on a concrete driver
///     class. This Mac answers with `AGXAcceleratorG16X`; an Intel Mac answers
///     with `IntelAccelerator` and possibly an `AMDRadeonAccelerator` beside
///     it. Matching the family means the probe does not carry a list of chip
///     names that goes stale every autumn.
///
///   • When more than one accelerator answers, the busiest wins rather than the
///     mean. `busiest(of:)` is where that rule lives and why.
///
/// The trap is the percentage itself: it is the driver's average over a window
/// that is not our sampling interval, and it occasionally reports above 100
/// when those windows straddle. It is clamped rather than trusted, because a
/// bar chart that runs off its own axis is a bug report waiting to happen.
final class GraphicsProbe: ActivityProbe {

    let name = "graphics"

    /// Two failures, not one with a shared payload. The registry refusing to
    /// run the match has a `kern_return_t` worth printing; an iterator that ran
    /// and found nothing has only `KERN_SUCCESS` to offer, and "(0)" in an error
    /// message tells the reader nothing.
    enum Failure: Error, CustomStringConvertible {
        case matchFailed(kern_return_t)
        case noAccelerator

        var description: String {
            switch self {
            case .matchFailed(let code):
                return "IOAccelerator could not be matched (\(code))."
            case .noAccelerator:
                return "No IOAccelerator service is present."
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
            throw Failure.matchFailed(status)
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            accelerators.append(service)   // ownership moves into the array
            service = IOIteratorNext(iterator)
        }

        guard !accelerators.isEmpty else { throw Failure.noAccelerator }
    }

    func close() {
        for service in accelerators { IOObjectRelease(service) }
        accelerators = []
    }

    deinit {
        // The protocol puts the obligation on the probe. A dropped but unclosed
        // GraphicsProbe would otherwise leak one io_object per accelerator.
        close()
    }

    func read(into sample: inout ActivitySample) {
        let readings = accelerators.compactMap(Self.utilizationPercent(of:))
            .map(Self.utilization(fromPercent:))
        guard let busiest = Self.busiest(of: readings) else { return }
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

    /// The aggregation rule, pulled out of `read` so it can be stated once and
    /// tested. The busiest accelerator wins, never the mean: a Mac with an idle
    /// integrated GPU and a saturated discrete one is at 100% of the thing doing
    /// the work, and 50% would describe neither piece of hardware.
    static func busiest(of utilizations: [Double]) -> Double? {
        utilizations.max()
    }
}
