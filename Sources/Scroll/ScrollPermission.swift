import AppKit
import ApplicationServices

/// The doorman. 🚪
///
/// Reading scroll events needs nothing. *Changing* them needs Accessibility,
/// which is the first permission Taurine has ever asked for, so it is worth
/// being precise about what "granted" means.
///
/// The grant is not attached to an app, it is attached to a code identity. A
/// signed app keeps its identity across updates because the signature says so.
/// Taurine is ad-hoc signed and built from source, so its identity is a hash of
/// the binary: `./build.sh` produces a stranger. The switch in System Settings
/// stays on, `AXIsProcessTrusted()` starts answering false, and the feature is
/// dead while the settings pane insists it is alive. That specific
/// contradiction is why this type exists instead of one call at the point of
/// use: something has to be able to say it out loud.
///
/// The trap: the system prompt appears at most once per identity, and in the
/// stale-grant case it may not appear at all. So asking always offers the
/// settings pane as well, and the wording sends people to the minus button
/// rather than to a switch that is already on.
enum ScrollPermission {

    /// Whether this process may modify events right now. Cheap, no prompt, and
    /// live: a grant made while Taurine is running flips this without a restart.
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Ask. Shows the system prompt if the system is willing to show it, and
    /// opens the Accessibility pane either way, because the case where the
    /// prompt stays silent is exactly the case people need help with.
    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings()
    }

    /// Open System Settings straight at Privacy & Security ▸ Accessibility.
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// What to tell somebody whose scroll fix is switched on but not working.
    /// Names both halves of the confusion: never granted, and granted to a
    /// build that no longer exists.
    static let missingGrantExplanation =
        "macOS has not given Taurine permission to change scroll events.\n\n"
        + "Open System Settings ▸ Privacy & Security ▸ Accessibility and switch Taurine on. "
        + "If Taurine is already switched on there, it has been rebuilt since you granted it: "
        + "select it, remove it with the − button, then add it again."
}
