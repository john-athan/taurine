import Cocoa

/// The stage. 🎬
///
/// A borderless, click-through popover that drops out from under the menu bar
/// icon, plays the bull animation, shows *why* you're now awake, then fades.
/// It only exists during a toggle — no window, no timer, nothing while idle.
final class Toast {
    static let shared = Toast()

    private var window: NSWindow?
    private var timer: Timer?
    private let art = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")

    private init() {
        art.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        art.maximumNumberOfLines = 0
        art.isBezeled = false; art.drawsBackground = false
        art.textColor = .white

        caption.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        caption.isBezeled = false; caption.drawsBackground = false
        caption.textColor = NSColor.white.withAlphaComponent(0.75)
        caption.alignment = .center
    }

    /// Play `frames` under `button`, tinted, with a one-line reason caption.
    func play(_ frames: [String], near button: NSStatusBarButton?,
              tint: NSColor, caption text: String) {
        guard let button = button, let bwin = button.window else { return }
        timer?.invalidate()

        let w: CGFloat = 300, h: CGFloat = 116
        let win = window ?? makeWindow(w: w, h: h)
        window = win

        art.textColor = tint
        caption.stringValue = text
        art.stringValue = frames[0]

        let rectInWin = button.convert(button.bounds, to: nil)
        let onScreen = bwin.convertToScreen(rectInWin)
        win.setFrameOrigin(NSPoint(x: onScreen.midX - w / 2, y: onScreen.minY - h - 4))
        win.alphaValue = 1
        win.orderFront(nil)

        var i = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.11, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            i += 1
            if i < frames.count {
                self.art.stringValue = frames[i]
            } else {
                t.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    NSAnimationContext.runAnimationGroup({ c in
                        c.duration = 0.35
                        win.animator().alphaValue = 0
                    }, completionHandler: { win.orderOut(nil) })
                }
            }
        }
    }

    private func makeWindow(w: CGFloat, h: CGFloat) -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.ignoresMouseEvents = true
        win.hasShadow = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let card = NSView(frame: win.contentView!.bounds)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        card.layer?.cornerRadius = 12
        card.autoresizingMask = [.width, .height]

        art.frame = NSRect(x: 12, y: 30, width: w - 24, height: h - 40)
        art.autoresizingMask = [.width, .height]
        caption.frame = NSRect(x: 10, y: 8, width: w - 20, height: 18)
        caption.autoresizingMask = [.width]

        card.addSubview(art)
        card.addSubview(caption)
        win.contentView?.addSubview(card)
        return win
    }
}
