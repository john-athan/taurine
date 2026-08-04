import Foundation
import IOKit

/// The lever. 🔩
///
/// Underneath every charge limiter on macOS (AlDente, Battery, this one) sits
/// the same trick: the System Management Controller exposes a few undocumented
/// keys, and one of them decides whether the wall adapter is allowed to push
/// current into the cell. Write a byte, charging stops.
///
/// Everyone else ships a separate `smc` executable and spawns it per write. We
/// don't. AppleSMC is an IOKit service, IOKit is a C API, and Swift speaks C,
/// so this is one `IOServiceOpen` held for the life of the process instead of a
/// 56 KB GPL binary and a `fork`/`exec` every time the battery moves 1%.
///
/// The wire format is a fixed 80-byte struct with awkward interior padding:
/// `vers` is 2-aligned and `pLimitData` is 4-aligned, so there's a hole at byte
/// 10 and another before `data32`. Rather than trust Swift to reproduce a C
/// compiler's layout, we assemble the bytes by hand at explicit offsets and
/// read them back the same way. Boring, but it cannot silently drift.
final class SMC {

    /// Byte offsets into `SMCKeyData_t`, with the C padding applied:
    /// key@0, vers@4(6), pad@10, pLimitData@12(16), keyInfo@28(12),
    /// result@40, status@41, data8@42, pad@43, data32@44, bytes@48(32) = 80.
    private enum Off {
        static let key        = 0    // UInt32, FourCC in native byte order
        static let dataSize   = 28   // UInt32, keyInfo.dataSize
        static let dataType   = 32   // UInt32, keyInfo.dataType
        static let result     = 40   // UInt8
        static let data8      = 42   // UInt8, this is where the command goes
        static let payload    = 48   // 32 bytes
        static let payloadMax = 32
        static let size       = 80
    }

    /// Commands, written into `data8`.
    private enum Cmd {
        static let read: UInt8    = 5    // SMC_CMD_READ_BYTES
        static let write: UInt8   = 6    // SMC_CMD_WRITE_BYTES
        static let keyInfo: UInt8 = 9    // SMC_CMD_READ_KEYINFO
    }

    /// `kSMCHandleYPCEvent`, the one userclient selector AppleSMC exposes.
    private static let selector: UInt32 = 2

    /// `kSMCKeyNotFound`, returned in the `result` byte for a key this Mac lacks.
    private static let keyNotFound: UInt8 = 132

    enum Failure: Error, CustomStringConvertible {
        case unavailable
        case noSuchKey(String)
        case denied
        case sizeMismatch(String, expected: Int, got: Int)
        case io(String, Int32)

        var description: String {
            switch self {
            case .unavailable:
                return "AppleSMC is not reachable on this Mac."
            case .noSuchKey(let k):
                return "SMC key \(k) does not exist on this Mac."
            case .denied:
                return "SMC write refused. This has to run as root."
            case .sizeMismatch(let k, let want, let got):
                return "SMC key \(k) wants \(want) byte(s), got \(got)."
            case .io(let k, let c):
                return "SMC call for \(k) failed (0x\(String(UInt32(bitPattern: c), radix: 16)))."
            }
        }
    }

    private var conn: io_connect_t = 0

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { throw Failure.unavailable }
        defer { IOObjectRelease(service) }

        var c: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &c) == kIOReturnSuccess else {
            throw Failure.unavailable
        }
        conn = c
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    // MARK: - public surface

    /// Declared byte width of a key, or nil if this Mac has no such key.
    /// This doubles as the capability probe: `has("CHTE")` is how we tell a
    /// macOS 26 machine from an older one without sniffing version numbers.
    func width(of key: String) -> Int? {
        guard let out = try? call(packet(key, Cmd.keyInfo), key: key) else { return nil }
        return Int(Self.load32(out, Off.dataSize))
    }

    func has(_ key: String) -> Bool { width(of: key) != nil }

    func read(_ key: String) throws -> [UInt8] {
        guard let n = width(of: key) else { throw Failure.noSuchKey(key) }
        let out = try call(packet(key, Cmd.read, dataSize: n), key: key)
        return Array(out[Off.payload ..< Off.payload + min(n, Off.payloadMax)])
    }

    func write(_ key: String, _ bytes: [UInt8]) throws {
        guard let n = width(of: key) else { throw Failure.noSuchKey(key) }
        guard n == bytes.count else {
            throw Failure.sizeMismatch(key, expected: n, got: bytes.count)
        }
        _ = try call(packet(key, Cmd.write, dataSize: n, payload: bytes), key: key)
    }

    // MARK: - the round trip

    private func call(_ input: [UInt8], key: String) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Off.size)
        var outSize = Off.size

        let rc = input.withUnsafeBytes { inBuf in
            out.withUnsafeMutableBytes { outBuf in
                IOConnectCallStructMethod(conn, Self.selector,
                                          inBuf.baseAddress, Off.size,
                                          outBuf.baseAddress, &outSize)
            }
        }

        guard rc == kIOReturnSuccess else {
            // A write from a non-root process is rejected here, not in `result`.
            if rc == kIOReturnNotPrivileged || rc == kIOReturnNotPermitted {
                throw Failure.denied
            }
            throw Failure.io(key, rc)
        }

        switch out[Off.result] {
        case 0:                return out
        case Self.keyNotFound: throw Failure.noSuchKey(key)
        default:               throw Failure.io(key, Int32(out[Off.result]))
        }
    }

    private func packet(_ key: String, _ cmd: UInt8,
                        dataSize: Int = 0, payload: [UInt8] = []) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: Off.size)
        Self.store32(Self.fourCC(key), into: &p, at: Off.key)
        Self.store32(UInt32(dataSize), into: &p, at: Off.dataSize)
        p[Off.data8] = cmd
        for (i, b) in payload.prefix(Off.payloadMax).enumerated() { p[Off.payload + i] = b }
        return p
    }

    // MARK: - byte plumbing
    //
    // Explicit little-endian shuffling rather than `storeBytes(as:)`, which
    // requires the offset to be correctly aligned for the type. These are
    // alignment-proof and match what the C struct holds on every Mac Apple ships.

    private static func store32(_ v: UInt32, into p: inout [UInt8], at off: Int) {
        p[off]     = UInt8(truncatingIfNeeded: v)
        p[off + 1] = UInt8(truncatingIfNeeded: v >> 8)
        p[off + 2] = UInt8(truncatingIfNeeded: v >> 16)
        p[off + 3] = UInt8(truncatingIfNeeded: v >> 24)
    }

    private static func load32(_ p: [UInt8], _ off: Int) -> UInt32 {
        UInt32(p[off]) | UInt32(p[off + 1]) << 8 | UInt32(p[off + 2]) << 16 | UInt32(p[off + 3]) << 24
    }

    /// "CHTE" becomes 0x43485445, first character in the high byte.
    private static func fourCC(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for c in s.utf8.prefix(4) { v = (v << 8) | UInt32(c) }
        return v
    }
}
