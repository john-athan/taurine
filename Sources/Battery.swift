import Foundation
import IOKit.ps

/// The conscience. 🔋
///
/// Keeping a laptop awake all night on battery is how you wake up to 3%.
/// Taurine can watch the power source and, if you ask it to, drop the
/// assertion when the battery gets low on battery power. Event-driven: we
/// subscribe to power-source changes, we never poll.
final class Battery {
    /// Fires when the power situation changes (plugged/unplugged, % moved).
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?

    init() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx = ctx else { return }
            let me = Unmanaged<Battery>.fromOpaque(ctx).takeUnretainedValue()
            me.onChange?()
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
    }

    /// Current charge 0–100, or nil on desktops with no battery.
    var percent: Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return Int((Double(cur) / Double(max) * 100).rounded())
        }
        return nil
    }

    /// True when running on wall power (or a desktop with no battery).
    var onACPower: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return true }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let state = d[kIOPSPowerSourceStateKey] as? String
            else { continue }
            return state == kIOPSACPowerValue
        }
        return true
    }

    deinit {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode) }
    }
}
