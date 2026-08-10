import Foundation

/// The keyhole. 🔑
///
/// `IOReport` is where `powermetrics` gets its numbers, and it is the only way
/// to read this chip's energy counters without a root password (ADR 0003). It
/// is also private: no header, no stub library to link against, no promise it
/// will look the same next release. So Taurine does not link it. Every symbol
/// is fetched with `dlsym` at runtime and a missing one is a thrown error the
/// caller survives, which is what stops a future macOS from turning a menu bar
/// utility into a crash on launch.
///
/// The trap here is memory, and CoreFoundation's naming rules are the entire
/// contract. Every claim below was measured on this Mac, not assumed:
///
///   • `IOReportCopyAllChannels`, `IOReportCreateSubscription`,
///     `IOReportCreateSamples` and `IOReportCreateSamplesDelta` return +1.
///     Somebody has to give that back, and here that somebody is ARC: results
///     arrive through `takeRetainedValue()` and live in ordinary properties, so
///     the retain we were handed is the one ARC releases.
///   • `IOReportCreateSubscription` *also* writes a dictionary into its third
///     argument, and that one is +1 too. It is easy to miss because nothing
///     ever reads it. Read through a raw function pointer, so that ARC never
///     touches the object and cannot inflate the answer, it comes back with a
///     retain count of one: ours, and nobody else's. So it is released on the
///     spot. Handing that argument a null pointer is not an option: the
///     function writes through it unconditionally.
///   • Every `…Get…` accessor is +0. The unit labels are immortal constants
///     (retain count 0x7FFFFFFFFFFFFFFF, and 0x0FFFFFFFFFFFFFFF for the empty
///     one the unlabelled channels share). The channel names are not: they are
///     ordinary strings the channel dictionary owns, and two million calls to
///     that accessor left one of them at a retain count of 2 and moved the
///     process footprint by zero bytes. Neither kind is released.
///   • The subscription handle is a CoreFoundation object even though its type
///     is opaque, so `CFRelease` is how it goes back. It also costs the task
///     exactly one mach port name, which is the handle the leak tests pull on:
///     twenty live subscriptions are twenty extra names, and releasing them
///     puts the count back where it started, to the name.
///
/// The other trap is scale. This Mac publishes more than ten thousand channels
/// (10,365 of them one minute and 10,367 the next), and sampling all of them
/// means building a ten-thousand entry dictionary twice per tick. The
/// subscription is therefore filtered down to the handful of groups the panel
/// needs before it is ever created: a sample and a delta over all of them takes
/// 110 ms, and over the 293 the panel actually reads, 4.
final class IOReportBridge {

    // MARK: - what can go wrong

    enum Failure: Error, CustomStringConvertible {
        case libraryMissing
        case symbolMissing(String)
        case noChannelLegend
        case legendNotCopied
        case nothingMatched
        case subscriptionRefused
        case sampleRefused

        var description: String {
            switch self {
            case .libraryMissing:
                return "libIOReport is not present on this Mac."
            case .symbolMissing(let name):
                return "libIOReport on this macOS has no \(name)."
            case .noChannelLegend:
                return "IOReport published no channel legend."
            case .legendNotCopied:
                return "CoreFoundation would not allocate a filtered copy of the channel legend."
            case .nothingMatched:
                return "IOReport publishes none of the channels the power tile needs."
            case .subscriptionRefused:
                return "IOReport refused the subscription."
            case .sampleRefused:
                return "IOReport refused to produce a sample."
            }
        }
    }

    /// A slice of the channel legend to subscribe to. A nil `subgroup` takes
    /// every subgroup of the group, which is what the energy counters need:
    /// they sit in a group with no subgroup at all.
    struct Selection {
        let group: String
        let subgroup: String?

        init(_ group: String, _ subgroup: String? = nil) {
            self.group = group
            self.subgroup = subgroup
        }

        func matches(group: String, subgroup: String) -> Bool {
            self.group == group && (self.subgroup == nil || self.subgroup == subgroup)
        }
    }

    /// Counters as they stood at one instant. Cumulative, and therefore only
    /// meaningful next to another one.
    struct Snapshot {
        fileprivate let dictionary: CFDictionary
        /// `ProcessInfo.systemUptime` when the counters were read. Monotonic,
        /// because a wall clock adjustment mid-interval would turn a watt into
        /// an arbitrary number.
        let uptime: TimeInterval
    }

    /// One channel's worth of a difference between two snapshots.
    struct Item {
        let group: String
        let subgroup: String
        let channel: String
        /// The channel's own unit label, whitespace trimmed. `mJ`, `uJ`, `nJ`
        /// for energy, `24Mticks` for residency on this Mac. Never assumed.
        let unit: String
        fileprivate let raw: CFDictionary
    }

    /// One state of a residency channel, over the interval.
    struct Residency {
        let name: String
        let ticks: Int64
    }

    // MARK: - the symbols

    private struct Functions {
        typealias CopyAllChannels = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
        typealias CreateSubscription = @convention(c) (
            UnsafeRawPointer?, CFMutableDictionary,
            UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?
        ) -> UnsafeRawPointer?
        typealias CreateSamples = @convention(c) (UnsafeRawPointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
        typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
        typealias ChannelText = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
        /// The second argument is an out-parameter, not an index. Handed a
        /// pointer it writes eight bytes through it and returns the counter
        /// anyway; handed null it just returns the counter, which is all this
        /// side of the app has any use for. Typing it as an integer would be a
        /// loaded gun: the callee dereferences whatever those sixty-four bits
        /// hold. `IOReportStateGetResidency` below, whose second argument
        /// really is a state index, is the one that takes an `Int32`.
        typealias ChannelInteger = @convention(c) (CFDictionary, UnsafeMutableRawPointer?) -> Int64
        typealias StateCount = @convention(c) (CFDictionary) -> Int32
        typealias StateText = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
        typealias StateInteger = @convention(c) (CFDictionary, Int32) -> Int64

        let copyAllChannels: CopyAllChannels
        let createSubscription: CreateSubscription
        let createSamples: CreateSamples
        let createDelta: CreateDelta
        let group: ChannelText
        let subgroup: ChannelText
        let channelName: ChannelText
        let unitLabel: ChannelText
        let integerValue: ChannelInteger
        let stateCount: StateCount
        let stateName: StateText
        let stateResidency: StateInteger

        static func load() throws -> Functions {
            // RTLD_LAZY, and never dlclose: the image lives in the dyld shared
            // cache, so this costs nothing to keep and would cost a page fault
            // storm to re-resolve on every panel open.
            guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else {
                throw Failure.libraryMissing
            }
            func resolve<T>(_ name: String) throws -> T {
                guard let symbol = dlsym(handle, name) else { throw Failure.symbolMissing(name) }
                return unsafeBitCast(symbol, to: T.self)
            }
            return Functions(
                copyAllChannels: try resolve("IOReportCopyAllChannels"),
                createSubscription: try resolve("IOReportCreateSubscription"),
                createSamples: try resolve("IOReportCreateSamples"),
                createDelta: try resolve("IOReportCreateSamplesDelta"),
                group: try resolve("IOReportChannelGetGroup"),
                subgroup: try resolve("IOReportChannelGetSubGroup"),
                channelName: try resolve("IOReportChannelGetChannelName"),
                unitLabel: try resolve("IOReportChannelGetUnitLabel"),
                integerValue: try resolve("IOReportSimpleGetIntegerValue"),
                stateCount: try resolve("IOReportStateGetCount"),
                stateName: try resolve("IOReportStateGetNameForIndex"),
                stateResidency: try resolve("IOReportStateGetResidency"))
        }
    }

    /// Resolved once for the life of the process. A probe that opens and closes
    /// fifty times should not walk the symbol table fifty times, and the answer
    /// cannot change while we run.
    private static let library: Result<Functions, Failure> = {
        do { return .success(try Functions.load()) }
        catch let failure as Failure { return .failure(failure) }
        catch { return .failure(.libraryMissing) }
    }()

    /// The key every IOReport dictionary hangs its channel array off.
    private static let channelsKey = "IOReportChannels" as CFString

    // MARK: - state

    private let fn: Functions
    /// The filtered legend. Handed to every `createSamples` call, so it has to
    /// outlive the subscription. ARC owns it.
    private let channels: CFMutableDictionary
    /// Opaque, CoreFoundation-managed, released by hand in `deinit`. Assigned
    /// once and never cleared, so there is no state in which a bridge exists
    /// without one.
    private let subscription: UnsafeRawPointer

    // MARK: - opening and closing

    /// Subscribe to just the named slices of the legend. Throws rather than
    /// returning an empty subscription when nothing matches, because a probe
    /// that opens successfully and then reports nothing forever is worse than
    /// one that says out loud it is not supported here.
    init(subscribingTo selections: [Selection]) throws {
        let fn = try Self.library.get()
        self.fn = fn

        guard let legend = fn.copyAllChannels(0, 0)?.takeRetainedValue(),
              let published = Self.channelArray(of: legend) else {
            throw Failure.noChannelLegend
        }
        guard let wanted = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, legend) else {
            throw Failure.legendNotCopied
        }

        guard let keep = withUnsafePointer(to: kCFTypeArrayCallBacks, {
            CFArrayCreateMutable(kCFAllocatorDefault, 0, $0)
        }) else {
            throw Failure.legendNotCopied
        }
        for index in 0..<CFArrayGetCount(published) {
            guard let entry = CFArrayGetValueAtIndex(published, index) else { continue }
            let item = Unmanaged<CFDictionary>.fromOpaque(entry).takeUnretainedValue()
            let group = Self.text(fn.group(item))
            let subgroup = Self.text(fn.subgroup(item))
            guard selections.contains(where: { $0.matches(group: group, subgroup: subgroup) }) else { continue }
            CFArrayAppendValue(keep, entry)
        }
        guard CFArrayGetCount(keep) > 0 else { throw Failure.nothingMatched }

        CFDictionarySetValue(wanted,
                             Unmanaged.passUnretained(Self.channelsKey).toOpaque(),
                             Unmanaged.passUnretained(keep).toOpaque())
        self.channels = wanted

        // The third argument is written through unconditionally, and what lands
        // there is ours to release. See the note at the top of the file.
        var handback: Unmanaged<CFMutableDictionary>?
        guard let subscription = fn.createSubscription(nil, wanted, &handback, 0, nil) else {
            handback?.release()
            throw Failure.subscriptionRefused
        }
        handback?.release()
        self.subscription = subscription
    }

    deinit {
        // Swift hides `CFRelease` behind ARC, and the subscription is the one
        // CoreFoundation object here that ARC never saw. `Unmanaged.release()`
        // is the same decrement under a different name, and it is what gives
        // the task its mach port name back.
        Unmanaged<AnyObject>.fromOpaque(subscription).release()
    }

    // MARK: - reading

    /// Read every subscribed counter as it stands right now.
    func snapshot() throws -> Snapshot {
        guard let dictionary = fn.createSamples(subscription, channels, nil)?.takeRetainedValue() else {
            throw Failure.sampleRefused
        }
        return Snapshot(dictionary: dictionary, uptime: ProcessInfo.processInfo.systemUptime)
    }

    /// Subtract two snapshots. The items handed back retain their own backing
    /// dictionaries, so they stay valid after the delta itself goes away.
    func difference(from earlier: Snapshot, to later: Snapshot) throws -> [Item] {
        guard let delta = fn.createDelta(earlier.dictionary, later.dictionary, nil)?.takeRetainedValue(),
              let published = Self.channelArray(of: delta) else {
            throw Failure.sampleRefused
        }

        var items: [Item] = []
        items.reserveCapacity(CFArrayGetCount(published))
        for index in 0..<CFArrayGetCount(published) {
            guard let entry = CFArrayGetValueAtIndex(published, index) else { continue }
            let raw = Unmanaged<CFDictionary>.fromOpaque(entry).takeUnretainedValue()
            items.append(Item(group: Self.text(fn.group(raw)),
                              subgroup: Self.text(fn.subgroup(raw)),
                              channel: Self.text(fn.channelName(raw)),
                              unit: Self.text(fn.unitLabel(raw)).trimmingCharacters(in: .whitespaces),
                              raw: raw))
        }
        return items
    }

    /// The single accumulated number on a simple counter channel. The
    /// accessor's out-parameter is declined: the number is the return value.
    func integerValue(of item: Item) -> Int64 {
        fn.integerValue(item.raw, nil)
    }

    /// Per-state residency on a state channel, in the channel's own tick unit,
    /// in the order the hardware declares its states.
    func residencies(of item: Item) -> [Residency] {
        let count = fn.stateCount(item.raw)
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let name = fn.stateName(item.raw, index).map { Self.text($0) } ?? "S\(index)"
            return Residency(name: name, ticks: fn.stateResidency(item.raw, index))
        }
    }

    // MARK: - CoreFoundation plumbing

    /// Every IOReport dictionary, legend or sample or delta, is a wrapper round
    /// one array under this key. Reached with the C API rather than a Swift
    /// bridge cast, so the entries stay the very objects IOReport handed us.
    private static func channelArray(of dictionary: CFDictionary) -> CFArray? {
        guard let value = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(channelsKey).toOpaque()) else {
            return nil
        }
        let object = Unmanaged<CFTypeRef>.fromOpaque(value).takeUnretainedValue()
        guard CFGetTypeID(object) == CFArrayGetTypeID() else { return nil }
        return (object as! CFArray)
    }

    /// +0 in, `String` out. The accessors return borrowed strings, so this
    /// takes them unretained and copies the characters into Swift's own
    /// storage, which is the only thing that outlives the sample.
    private static func text(_ value: Unmanaged<CFString>?) -> String {
        guard let value else { return "" }
        return value.takeUnretainedValue() as String
    }
}
