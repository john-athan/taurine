import Cocoa
import Carbon.HIToolbox

/// The reflex. ⌨️
///
/// A single global hotkey (default ⌃⌥⌘R) toggles Taurine from anywhere.
/// We use Carbon's `RegisterEventHotKey` on purpose: unlike a global NSEvent
/// monitor, it needs **no Accessibility permission** — nothing for the user to
/// approve, nothing to break on macOS updates.
final class Hotkey {
    private var ref: EventHotKeyRef?
    private let action: () -> Void

    init(keyCode: UInt32 = UInt32(kVK_ANSI_R),
         modifiers: UInt32 = UInt32(cmdKey | optionKey | controlKey),
         action: @escaping () -> Void) {
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            let me = Unmanaged<Hotkey>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.action() }
            return noErr
        }, 1, &spec, ctx, nil)

        let id = EventHotKeyID(signature: 0x54415552 /* 'TAUR' */, id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit { if let r = ref { UnregisterEventHotKey(r) } }
}
