import ApplicationServices

/// The one question asked of Finder itself. 🔎
///
/// Renaming a file is the case that decides whether this feature is welcome or
/// hated. A rename puts a text field on screen, and in a text field ⌘X means cut
/// this text, which Finder already does correctly. Rewriting it into ⌘C there
/// would turn every rename into a copy that silently leaves the old text behind.
/// The same goes for the search field and for the comments box in Get Info.
///
/// So before rewriting anything, Taurine asks Finder what it has focused. That
/// is an Accessibility question, answered by Finder over a Mach round trip, and
/// it is the only call in this feature that leaves the process. Two properties
/// make it affordable from a tap callback:
///
///   * It is only asked for ⌘X, ⌘C and ⌘V, and only while Finder is frontmost.
///     Every other keystroke on the machine is decided by four integer
///     comparisons and never reaches this file.
///   * It is bounded. `AXUIElementSetMessagingTimeout` is set on the element in
///     `FinderKeyTap`, so a wedged Finder costs one keystroke's worth of delay
///     rather than the tap itself: macOS switches off a tap that stops
///     answering, and this is the only place that could plausibly stall.
///
/// Measured on this Mac, warm, from a background thread: 38 µs per question.
///
/// **Which way it fails.** A question that cannot be answered (Finder busy,
/// Accessibility revoked mid-session, an element with no role) is treated as
/// "not editing text", so the rewrite goes ahead. The alternative was tried on
/// paper and is worse: a feature that quietly stops working whenever a probe
/// fails is one nobody can report a bug about, whereas the failure this way
/// round is ⌘X copying instead of cutting inside a rename box, which is visible,
/// harmless, and undone with ⌘Z.
enum FinderFocus {

    /// Whether the focused element in `app` is something you type into.
    ///
    /// The list is an allowlist of roles Finder actually uses for editable text:
    /// the rename field and the search field are text fields, Get Info's
    /// comments box is a text area, and a combo box is a text field with a menu
    /// bolted on. Everything else Finder can focus (the icon view, the list, the
    /// sidebar outline, the desktop group) is not text.
    static func isEditingText(_ app: AXUIElement) -> Bool {
        guard let focused = copyElement(app, kAXFocusedUIElementAttribute),
              let role = copyString(focused, kAXRoleAttribute)
        else { return false }
        return role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}
