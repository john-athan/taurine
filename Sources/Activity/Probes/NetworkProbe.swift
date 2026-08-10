import Foundation

/// The turnstile. 🌐
///
/// `net.link.generic.ifdata.<index>.general` answers with one `ifmibdata` per
/// interface, and the `if_data64` inside it carries that interface's lifetime
/// byte counters. `netstat -ib` reads exactly this. That is the whole mechanism.
/// Everything interesting here is about which interfaces to count.
///
/// **Why not `getifaddrs`.** Its `if_data` counts bytes in `u_int32_t`, so the
/// number it publishes is the true count modulo 4 GiB. A rate probe can hide
/// that by reconstructing the roll-over, but a *total* cannot: the missing
/// gigabytes went missing before Taurine ever saw the counter, so there is
/// nothing to reconstruct from and the error never heals. Measured on this Mac
/// at one instant: `en0` has sent 4_979_514_727 bytes, and `getifaddrs` reports
/// 684_542_976 for it. The difference is 4 GiB exactly.
///
/// **Why not the routing socket.** `sysctl(NET_RT_IFLIST2)` publishes the same
/// `if_data64` and would do in one call what this does in one per interface.
/// Measured on this Mac, though, it floors every byte counter to a multiple of
/// 1024, and so does `getifaddrs`: `en0` read 1_771_013_120 through both while
/// `netstat` and this MIB read 1_771_014_114 at the same moment. Packet counts
/// come through exact, only bytes are rounded. The per interface walk costs
/// 8 microseconds against the routing socket's 21 (the routing socket carries
/// every address as well), so the exact number is also the cheaper one.
///
/// **What is excluded, and why.** Every exclusion here answers the same
/// question: were these bytes already counted on another interface?
///
///   • Loopback (`IFF_LOOPBACK`, `IFT_LOOP`). A gigabyte and a half has crossed
///     `lo0` on this machine since boot and none of it went anywhere. `top`'s
///     Networks line does include it, which is why `top` and this probe
///     disagree by exactly the loopback figure.
///   • Encapsulation. A tunnel's payload is carried again by the physical link
///     underneath it, so counting both doubles every byte through a VPN. The
///     `utun*` tunnels are caught by `IFF_POINTOPOINT`; `IFT_GIF` and `IFT_STF`
///     are named because they are tunnels whether or not they carry that flag.
///     Verified on this machine: `stf0` reports flags of zero, so before its
///     type was named here it was counted.
///   • Bridges, VLANs and link aggregates (`IFT_BRIDGE`, `IFT_L2VLAN`,
///     `IFT_IEEE8023ADLAG`). Same double count: a bridge's counters are the sum
///     of its members' and both are visible here.
///
/// **What this cannot promise.** A layer 2 VPN of the TAP kind presents as
/// `IFT_ETHER` and is not point to point, so it is indistinguishable from a
/// physical link through any public interface, and its bytes are counted twice.
/// No list of types fixes that, because the kernel does not publish which
/// interface carries which. The exclusions above are the cases macOS itself
/// creates, not a proof that nothing is ever counted twice.
///
/// **What is deliberately kept.** `awdl0` and `llw0` carry AirDrop and
/// low-latency Wi-Fi over the same radio as `en0`, but they are separate links
/// with separate counters and nothing double counts. `anpi*` are the internal
/// links to the co-processors and `ap1` is the hotspot access point: real
/// traffic over real links, usually idle, and excluding them would mean
/// deciding which of the machine's networking is not networking.
final class NetworkProbe: ActivityProbe {

    let name = "network"

    enum Failure: Error, CustomStringConvertible {
        case sysctl(Int32)
        case noInterfaces

        var description: String {
            switch self {
            case .sysctl(let code):
                return "net.link.generic did not answer (errno \(code))."
            case .noInterfaces:
                return "No countable network interfaces were found."
            }
        }
    }

    private var ledger = TrafficLedger<String>()

    // MARK: - lifecycle

    func open() throws {
        close()
        guard let readings = Self.interfaceCounters() else { throw Failure.sysctl(errno) }
        guard !readings.isEmpty else { throw Failure.noInterfaces }
        // The baseline, taken here rather than on the first `read`, so the first
        // frame the panel draws carries a real rate.
        _ = ledger.update(readings, over: 0)
    }

    func close() {
        // The walk allocates nothing that outlives it, so nothing is held
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
    ///
    /// Nil only when the kernel refused to say how many interfaces there are,
    /// which is the one case `errno` describes. An interface that answers
    /// `ENOENT` mid walk was destroyed between the count and the read, which is
    /// a dock being unplugged, not a failure.
    static func interfaceCounters() -> [String: ByteCounters]? {
        var total: Int32 = 0
        var totalSize = MemoryLayout<Int32>.size
        var totalMIB: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT]
        guard sysctl(&totalMIB, 5, &total, &totalSize, nil, 0) == 0 else { return nil }

        var readings: [String: ByteCounters] = [:]
        for index in stride(from: 1, through: total, by: 1) {
            var entry = ifmibdata()
            var size = MemoryLayout<ifmibdata>.size
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, index, IFDATA_GENERAL]
            guard sysctl(&mib, 6, &entry, &size, nil, 0) == 0 else { continue }
            guard counts(flags: interfaceFlags(of: entry), type: entry.ifmd_data.ifi_type) else { continue }

            readings[interfaceName(of: entry)] = ByteCounters(inbound: entry.ifmd_data.ifi_ibytes,
                                                             outbound: entry.ifmd_data.ifi_obytes)
        }
        return readings
    }

    /// `ifmd_name` is a fixed `char[IFNAMSIZ]` padded with zeroes.
    private static func interfaceName(of entry: ifmibdata) -> String {
        withUnsafeBytes(of: entry.ifmd_name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// `ifmd_flags` is `unsigned int`, but the kernel fills it from a signed
    /// short, so every interface carrying `IFF_MULTICAST` (0x8000) arrives with
    /// the top sixteen bits set: `lo0` reads 0xffff8049 where `ifconfig` says
    /// 0x8049. Every `IFF_` flag fits in those low sixteen bits, so the sign
    /// extension is dropped rather than reasoned about.
    private static func interfaceFlags(of entry: ifmibdata) -> UInt32 {
        entry.ifmd_flags & 0xFFFF
    }

    /// Whether an interface's bytes belong in the machine's total. Pure, so the
    /// exclusion policy can be checked against interfaces this Mac does not
    /// have.
    static func counts(flags: UInt32, type: UInt8) -> Bool {
        if flags & UInt32(IFF_LOOPBACK) != 0 { return false }
        if flags & UInt32(IFF_POINTOPOINT) != 0 { return false }

        switch Int32(type) {
        case IFT_LOOP, IFT_GIF, IFT_STF, IFT_BRIDGE, IFT_L2VLAN, IFT_IEEE8023ADLAG: return false
        default: return true
        }
    }
}
