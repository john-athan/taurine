import Foundation
import ServiceManagement

/// The habit. 🌅
///
/// Thin wrapper over `SMAppService.mainApp` — the modern (macOS 13+) way to be
/// a login item. No helper bundle, no AppleScript poking at System Events, no
/// permissions dialog beyond the one-tap toggle in System Settings.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Flip it. Returns nil on success, or an error message to show the user.
    static func toggle() -> String? {
        do {
            if isEnabled { try SMAppService.mainApp.unregister() }
            else         { try SMAppService.mainApp.register() }
            return nil
        } catch {
            return "\(error.localizedDescription)\n\nMove Taurine.app to /Applications and try again."
        }
    }
}
