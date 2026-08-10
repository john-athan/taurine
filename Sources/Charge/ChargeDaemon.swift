import Foundation
import IOKit
import IOKit.pwr_mgt
import os

/// The night shift. 🌙
///
/// Runs as root from a LaunchDaemon and owns exactly one thing: the SMC charge
/// inhibit bit. The menu bar app never touches it.
///
/// The whole design rule here is *no timers*. A charge limiter that wakes up
/// every 30 seconds to check a percentage is a charge limiter that costs you
/// battery to save your battery, which is silly. Everything below is a kernel
/// push:
///
///   • `IOPSNotificationCreateRunLoopSource` fires when the power source moves
///     (plugged, unplugged, percentage changed). Reused verbatim from `Battery`.
///   • `IORegisterForSystemPower` fires on wake, because the SMC bit does not
///     reliably survive sleep and has to be re-asserted.
///   • a kqueue on the config directory fires when the menu writes a new limit.
///
/// Between those, the process sits blocked in `mach_msg` at 0% CPU with no
/// scheduled work at all. Idle cost is a few MB of resident memory and nothing
/// else. For comparison, the Electron app this replaces held ~217 MB across
/// four processes to render one status bar glyph.
final class ChargeDaemon {

    /// `IOMessage.h` builds these with the `iokit_common_msg` macro, which Swift
    /// can't evaluate, so the constants don't survive the C import. These are the
    /// expanded values (sys_iokit 0x38 << 26, sub_iokit_common 0), verified
    /// against the SDK header by compiling it.
    private enum PowerMessage {
        static let canSystemSleep: UInt32     = 0xE000_0270
        static let systemWillSleep: UInt32    = 0xE000_0280
        static let systemHasPoweredOn: UInt32 = 0xE000_0300
    }

    /// How far the cell may fall below the limit before we let current back in.
    /// Without a deadband the SMC would flap on and off at the boundary; with it
    /// we write to the SMC a couple of times a day and otherwise do nothing.
    static let resumeMargin = 3

    private let log = Logger(subsystem: "io.github.john-athan.taurine", category: "charge")

    private var governor: ChargeGovernor!
    private let battery = Battery()

    private var configDirWatch: DispatchSourceFileSystemObject?
    private var configFileWatch: DispatchSourceFileSystemObject?
    private var signalSources: [DispatchSourceSignal] = []

    private var powerRoot: io_connect_t = 0
    private var powerNotifier: io_object_t = 0
    private var powerPort: IONotificationPortRef?

    // MARK: - entry point

    func run() -> Int32 {
        guard geteuid() == 0 else {
            FileHandle.standardError.write(Data(
                "taurine: --charge-daemon has to run as root (it writes the SMC).\n".utf8))
            return 1
        }

        let smc: SMC
        do {
            smc = try SMC()
        } catch {
            log.error("cannot open AppleSMC: \(String(describing: error), privacy: .public)")
            return 1
        }

        governor = ChargeGovernor(smc: smc)
        log.notice("charge daemon up, SMC path \(self.governor.path.rawValue, privacy: .public)")

        guard governor.path.isSupported else {
            log.error("no usable SMC charge key on this Mac, exiting")
            return 1
        }

        // Recover first, always. If a predecessor was SIGKILLed while holding the
        // inhibit bit, the Mac is sitting there refusing to charge and nothing
        // else on the system will ever put it back. Clear it, then reconcile.
        governor.setCharging(permitted: true)

        installSignalHandlers()
        watchConfig()
        watchPower()
        watchSleepWake()

        reconcile()
        CFRunLoopRun()
        return 0
    }

    /// The escape hatch, run as root by `taurine batt unlock`.
    ///
    /// The inhibit bit lives in the SMC, not in this process, so a `SIGKILL` at
    /// the wrong moment leaves a Mac that silently refuses to charge and no
    /// process to point at. `KeepAlive` plus the recover-on-start above covers
    /// that in practice, but "in practice" is not much comfort at 3% battery.
    /// This clears the bit unconditionally and exits.
    static func forcePermitCharging() -> Int32 {
        guard geteuid() == 0 else {
            FileHandle.standardError.write(Data("taurine: unlock has to run as root.\n".utf8))
            return 1
        }
        guard let smc = try? SMC() else {
            FileHandle.standardError.write(Data("taurine: cannot reach AppleSMC.\n".utf8))
            return 1
        }
        let g = ChargeGovernor(smc: smc)
        if let err = g.setCharging(permitted: true) {
            FileHandle.standardError.write(Data("taurine: \(err)\n".utf8))
            return 1
        }
        print("🔋 Charging permitted (SMC \(g.path.rawValue)).")
        return 0
    }

    // MARK: - the decision

    /// Drive the SMC toward what the config asks for. Cheap, idempotent, and
    /// safe to call from any of the three event sources.
    private func reconcile() {
        let limit = ChargeConfig.read()
        let permitted = governor.chargingPermitted
        let onAC = battery.onACPower

        guard let pct = battery.percent else {
            // No battery at all (a Mac mini running this by mistake). Leave the
            // machine exactly as we found it.
            writeState(limit: limit, percent: nil, permitted: permitted, onAC: onAC)
            return
        }

        let want: Bool
        if let limit {
            if pct >= limit {
                want = false
            } else if pct <= limit - Self.resumeMargin {
                want = true
            } else {
                // Inside the deadband: hold whatever we're already doing, so a
                // percentage jittering across 78/79 doesn't rewrite the SMC.
                want = permitted ?? true
            }
        } else {
            want = true
        }

        if permitted != want {
            if let err = governor.setCharging(permitted: want) {
                log.error("SMC write failed: \(err, privacy: .public)")
            } else {
                log.notice("charging \(want ? "permitted" : "inhibited", privacy: .public) at \(pct)%, limit \(limit.map(String.init) ?? "off", privacy: .public)")
            }
        }

        writeState(limit: limit, percent: pct, permitted: want, onAC: onAC)
    }

    private func writeState(limit: Int?, percent: Int?, permitted: Bool?, onAC: Bool) {
        let s = ChargeState(limit: limit, percent: percent, permitted: permitted,
                            path: governor.path, onAC: onAC)
        try? s.serialized().write(toFile: ChargePaths.state, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: ChargePaths.state)
    }

    // MARK: - event sources

    /// Power source changes. Same primitive the menu bar app already uses.
    private func watchPower() {
        battery.onChange = { [weak self] in self?.reconcile() }
    }

    /// Two kqueues, because one isn't enough and finding that out the hard way
    /// is exactly the sort of silent failure this daemon must not have.
    ///
    /// `ChargeConfig.write` replaces the file atomically, which unlinks the old
    /// vnode: a watch on the file alone goes deaf after the first change, so we
    /// watch the *directory* to catch the replacement. But a directory only
    /// reports entries appearing and disappearing, so an in-place edit
    /// (`echo 80 > limit`, or `nano`) changes the file without touching the
    /// directory at all, and a directory-only watch never fires.
    ///
    /// So: the directory watch catches atomic replaces, the file watch catches
    /// in-place edits, and each re-arms the file watch when the vnode is
    /// swapped underneath it. `reconcile` is idempotent, so the occasional
    /// double-fire when both sources see the same change costs nothing.
    private func watchConfig() {
        let fd = open(ChargePaths.configDir, O_EVTONLY)
        guard fd >= 0 else {
            log.error("cannot watch \(ChargePaths.configDir, privacy: .public)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            self?.armConfigFileWatch()      // the file we were watching may have been replaced
            self?.reconcile()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        configDirWatch = src

        armConfigFileWatch()
    }

    /// (Re)attach a watch to the limit file itself. Safe to call when the file
    /// doesn't exist yet; the directory watch will call us again when it appears.
    private func armConfigFileWatch() {
        configFileWatch?.cancel()
        configFileWatch = nil

        let fd = open(ChargePaths.limit, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename],
            queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.armConfigFileWatch()   // vnode replaced; follow the new one
            }
            self.reconcile()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        configFileWatch = src
    }

    /// Wake notifications. The SMC inhibit bit does not reliably survive sleep,
    /// so we re-assert on every wake.
    ///
    /// Registering here comes with an obligation: the kernel asks permission
    /// before sleeping and waits up to 30 seconds for an answer. Ignoring those
    /// messages would delay every sleep on the machine and cost far more battery
    /// than this daemon could ever save. So we acknowledge immediately.
    private func watchSleepWake() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        powerRoot = IORegisterForSystemPower(ctx, &powerPort, { ctx, _, messageType, arg in
            guard let ctx else { return }
            let me = Unmanaged<ChargeDaemon>.fromOpaque(ctx).takeUnretainedValue()
            switch messageType {
            case PowerMessage.canSystemSleep, PowerMessage.systemWillSleep:
                IOAllowPowerChange(me.powerRoot, Int(bitPattern: arg))
            case PowerMessage.systemHasPoweredOn:
                me.reconcile()
            default:
                break
            }
        }, &powerNotifier)

        guard powerRoot != 0, let port = powerPort else {
            log.error("could not register for sleep/wake")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .defaultMode)
    }

    // MARK: - never leave the bit set

    /// launchd sends SIGTERM on `bootout`, on shutdown, and on upgrade. Any exit
    /// we can see coming has to permit charging on the way out, otherwise the
    /// user is left with a Mac that will not charge and no process to blame.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)                     // required: the source replaces default handling
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.log.notice("signal \(sig), permitting charging before exit")
                self?.governor.setCharging(permitted: true)
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }
}
