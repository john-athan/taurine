import Foundation
import IOKit

/// The spindle. 💽
///
/// There is no public per-disk throughput API on macOS. What there is, is the
/// IO registry: every block device is driven by an `IOBlockStorageDriver`, and
/// each of those publishes a `Statistics` dictionary of lifetime counters, two
/// of which are the bytes read and written. `iostat` reads the same numbers.
/// They cost a registry property fetch, need no entitlement and no root, and
/// they are cumulative, so this is a rate probe and says nothing on the first
/// sample of a session.
///
/// The design decision worth stating is that the registry is searched again on
/// every tick rather than once in `open()`. Holding the `io_service_t` objects
/// would be cheaper and would be wrong twice over: an IOKit iterator is
/// one-shot, and a cached list of drivers cannot see a disk that was plugged in
/// after the panel opened, so external storage would be permanently invisible
/// to a panel somebody left open. A registry match is a fraction of a
/// millisecond, once a second, only while somebody is looking.
///
/// The trap underneath that is arithmetic, not IOKit: because the set of disks
/// changes, the counters must be differenced per disk and the *differences*
/// summed. `TrafficLedger` exists for exactly this, and the comment on it
/// explains what summing the readings instead would do the first time a USB
/// drive is connected.
///
/// A Mac reports several `IOBlockStorageDriver` instances, and idle ones with
/// all-zero statistics are normal (a card reader with no card, a disk image
/// backing store). They are counted anyway: zero is a true reading, and
/// filtering them would mean guessing which drivers are real.
final class StorageProbe: ActivityProbe {

    let name = "storage"

    enum Failure: Error, CustomStringConvertible {
        case noBlockStorage(kern_return_t)

        var description: String {
            switch self {
            case .noBlockStorage(let code):
                return "No IOBlockStorageDriver could be matched (\(code))."
            }
        }
    }

    /// Property names on `IOBlockStorageDriver`, spelled out rather than
    /// imported: they are `#define`d strings in IOKit's storage headers, whose
    /// visibility from Swift has not been reliable across toolchains. The
    /// constants they correspond to are named beside them.
    private enum Key {
        static let statistics = "Statistics"           // kIOBlockStorageDriverStatisticsKey
        static let bytesRead = "Bytes (Read)"          // ...StatisticsBytesReadKey
        static let bytesWritten = "Bytes (Write)"      // ...StatisticsBytesWrittenKey
    }

    /// 64 bit counters, so no modulus: a drop can only mean the driver went
    /// away and came back, which is a reset and gets no rate.
    private var ledger = TrafficLedger<UInt64>()

    // MARK: - lifecycle

    func open() throws {
        close()
        var status: kern_return_t = KERN_SUCCESS
        guard let readings = Self.statistics(status: &status), !readings.isEmpty else {
            throw Failure.noBlockStorage(status)
        }
    }

    func close() {
        // Nothing is held between ticks by design, so this is the whole of it:
        // the baselines go, and a reopened probe measures from scratch.
        ledger.forget()
    }

    func read(into sample: inout ActivitySample) {
        var status: kern_return_t = KERN_SUCCESS
        guard let readings = Self.statistics(status: &status) else { return }
        if let rate = ledger.update(readings, over: sample.interval) {
            sample.disk = rate
        }
    }

    // MARK: - the registry

    /// Lifetime byte counters for every block storage driver present, keyed by
    /// registry entry ID. The ID is used rather than the BSD name because it is
    /// unique for the life of the object and survives a disk being renamed,
    /// while `disk4` is reused the moment `disk4` is unplugged.
    static func statistics(status: inout kern_return_t) -> [UInt64: ByteCounters]? {
        var iterator: io_iterator_t = 0
        status = IOServiceGetMatchingServices(kIOMainPortDefault,
                                              IOServiceMatching("IOBlockStorageDriver"),
                                              &iterator)
        guard status == KERN_SUCCESS, iterator != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(iterator) }

        var readings: [UInt64: ByteCounters] = [:]
        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
            guard let property = IORegistryEntryCreateCFProperty(service,
                                                                 Key.statistics as CFString,
                                                                 kCFAllocatorDefault, 0),
                  let stats = property.takeRetainedValue() as? [String: Any] else { continue }

            // A driver that publishes the dictionary but not these two keys is
            // not a failure, it is a device that does not count bytes. Skipping
            // it is more honest than folding a zero into the total.
            guard let read = stats[Key.bytesRead] as? NSNumber,
                  let written = stats[Key.bytesWritten] as? NSNumber else { continue }

            readings[id] = ByteCounters(inbound: read.uint64Value, outbound: written.uint64Value)
        }
        return readings
    }
}
