import Foundation

/// The turnstile. 🌐
///
/// `getifaddrs` walks every address the machine has, and the entries whose
/// family is `AF_LINK` carry an `if_data` with that interface's lifetime byte
/// counters. That is the whole mechanism. Everything interesting here is about
/// which interfaces to count and what to do when a counter goes backwards.
///
/// **Only the `AF_LINK` entry.** An interface appears once per address it
/// holds, and every one of those entries reports the same interface-wide
/// counters. `en0` with a v4 address, a v6 address and a link-local would be
/// counted three times by a loop that forgot to filter on family, which is the
/// single easiest way to get this wrong and produce a number that is nearly
/// right on a laptop and triple on a server.
///
/// **What is excluded, and why.**
///
///   • Loopback (`IFF_LOOPBACK`). Half a gigabyte has crossed `lo0` on this
///     machine since boot, and none of it went anywhere. `top`'s Networks line
///     does include it, which is why `top` and this probe disagree by exactly
///     the loopback figure.
///   • Point to point links (`IFF_POINTOPOINT`): `utun*`, `gif*`, `ipsec*`. A
///     VPN's bytes are counted on the tunnel and then again on the physical
///     interface that actually carries them, so counting both doubles every
///     byte somebody sends through a VPN.
///   • Bridges and link aggregates. Same double count: a bridge's counters are
///     the sum of its members' and both are visible here. `sdl_type` names
///     these (`IFT_BRIDGE`, `IFT_L2VLAN`, `IFT_IEEE8023ADLAG`), but verified on
///     this machine, `bridge0` reports `IFT_ETHER` rather than `IFT_BRIDGE`, so
///     the interface name is checked as well. Interface names are assigned by
///     the driver family and `bridge`, `bond` and `vlan` are reserved by it, so
///     this is a narrower guess than it looks.
///
/// **What is deliberately kept.** `awdl0` and `llw0` carry AirDrop and
/// low-latency Wi-Fi over the same radio as `en0`, but they are separate links
/// with separate counters and nothing double counts. `anpi*` are the internal
/// links to the co-processors and `ap1` is the hotspot access point: real
/// traffic over real links, usually idle, and excluding them would mean
/// deciding which of the machine's networking is not networking.
///
/// **The wrap.** `if_data.ifi_ibytes` is `u_int32_t`, verified by measuring the
/// field on this machine, so every interface rolls over every 4 GiB. On a
/// gigabit transfer that is once every thirty-four seconds. `RateCounter` is
/// told the modulus so the roll-over is reconstructed exactly rather than
/// blanking the tile twice a minute. This is the reason that parameter exists.
final class NetworkProbe: ActivityProbe {

    let name = "network"

    enum Failure: Error, CustomStringConvertible {
        case noInterfaces

        var description: String {
            "No countable network interfaces were found."
        }
    }

    /// `if_data` counts in `u_int32_t`, so the counters roll over at 2^32.
    private static let counterModulus: UInt64 = 1 << 32

    private var ledger = TrafficLedger<String>(modulus: NetworkProbe.counterModulus)

    // MARK: - lifecycle

    func open() throws {
        close()
        guard let readings = Self.interfaceCounters(), !readings.isEmpty else {
            throw Failure.noInterfaces
        }
    }

    func close() {
        // `getifaddrs` allocates and frees inside one call, so nothing is held
        // between ticks and there is nothing to release. Only the baselines go.
        ledger.forget()
    }

    func read(into sample: inout ActivitySample) {
        guard let readings = Self.interfaceCounters() else { return }
        if let rate = ledger.update(readings, over: sample.interval) {
            sample.network = rate
        }
    }

    // MARK: - the walk

    /// Lifetime byte counters per counted interface, keyed by name. The name is
    /// stable for the life of the interface, which is what the ledger needs;
    /// two interfaces never share one at the same time.
    static func interfaceCounters() -> [String: ByteCounters]? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }

        var readings: [String: ByteCounters] = [:]
        var entry: UnsafeMutablePointer<ifaddrs>? = head

        while let current = entry {
            defer { entry = current.pointee.ifa_next }

            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = current.pointee.ifa_data else { continue }

            let name = String(cString: current.pointee.ifa_name)
            let type = address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) {
                $0.pointee.sdl_type
            }
            guard counts(name: name, flags: current.pointee.ifa_flags, type: type) else { continue }

            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            readings[name] = ByteCounters(inbound: UInt64(stats.ifi_ibytes),
                                          outbound: UInt64(stats.ifi_obytes))
        }
        return readings
    }

    /// Whether an interface's bytes belong in the machine's total. Pure, so the
    /// exclusion policy can be checked against interfaces this Mac does not
    /// have.
    static func counts(name: String, flags: UInt32, type: UInt8) -> Bool {
        if flags & UInt32(IFF_LOOPBACK) != 0 { return false }
        if flags & UInt32(IFF_POINTOPOINT) != 0 { return false }

        switch Int32(type) {
        case IFT_LOOP, IFT_BRIDGE, IFT_L2VLAN, IFT_IEEE8023ADLAG: return false
        default: break
        }

        // The name check backs up `sdl_type`, which reports IFT_ETHER for
        // bridge0 on this machine.
        for reserved in ["bridge", "bond", "vlan"] where name.hasPrefix(reserved) {
            return false
        }
        return true
    }
}
