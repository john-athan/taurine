import ApplicationServices

/// Where in Finder the keystroke landed. 🔎
///
/// Three fixes ask this, and they want different things from it, which is why
/// the answer has three values rather than two.
///
/// Renaming a file is the case that decides whether any of this is welcome or
/// hated. A rename puts a text field on screen, and in a text field ⌘X means cut
/// this text and ⌫ means delete a character, both of which Finder already does
/// correctly. So before rewriting anything, Taurine asks Finder what it has
/// focused. That is an Accessibility question, answered by Finder over a Mach
/// round trip, and it is the only call in these fixes that leaves the process.
/// Two properties make it affordable from a tap callback:
///
///   * It is only asked for the seven keys the fixes care about, and only while
///     Finder is frontmost. Every other keystroke on the machine is decided by
///     a handful of integer comparisons and never reaches this file.
///   * It is bounded. `AXUIElementSetMessagingTimeout` is set on the element in
///     `FinderKeyTap`, so a wedged Finder costs one keystroke's worth of delay
///     rather than the tap itself: macOS switches off a tap that stops
///     answering, and this is the only place that could plausibly stall.
///
/// Measured on this Mac, warm, from a background thread: 92 µs for an answer
/// that stops at the role, 133 µs for one that has to walk to the parent as
/// well. Both are far inside the budget; neither is free enough to ask twice.
///
/// **Which way it fails, and why that is now two answers.** `.unknown` is
/// returned for a question that could not be answered at all, and each fix
/// decides for itself what to do with that:
///
///   * The cut fix treats `.unknown` as "go ahead". A probe failure there costs
///     a copy instead of a cut, which is visible, harmless and undone with ⌘Z,
///     whereas a fix that quietly stops working whenever a probe fails is one
///     nobody can report a bug about.
///   * The ⌫ and ⏎ fixes treat `.unknown` as "do nothing". ⌫ moves files to the
///     Trash, so the same failure that costs the cut fix a copy would cost this
///     one a file, and the safe direction is the key going on doing what it has
///     always done. They rewrite only on `.fileList`, which is a positive
///     statement that Finder has a list of files focused.
///
/// That second rule is not theoretical. Measured against a real Finder: while a
/// modal sheet is up (the "an item with that name already exists" dialog, for
/// one) this question is not answered at all, and `.unknown` is what keeps ⌫
/// and ⏎ out of a dialog they have no business being in.
enum FinderSurface: Equatable {

    /// Something you type into: the rename field, the search field, Go to
    /// Folder, Get Info's comments box.
    case text

    /// A list of files: any of Finder's four views, or the desktop.
    case fileList

    /// Anything else, *and* every question Finder did not answer.
    case unknown
}

enum FinderFocus {

    /// What the focused element in `app` is, as far as Accessibility will say.
    ///
    /// The roles are an allowlist twice over. For text it is the roles Finder
    /// actually uses for editable text: the rename and search fields are text
    /// fields, Get Info's comments box is a text area, and a combo box is a
    /// text field with a menu bolted on.
    ///
    /// For file lists it is what the four views and the desktop were measured
    /// to report, each of them sitting directly inside a scroll area:
    ///
    ///     list view      AXOutline   id ListView
    ///     icon view      AXList      id IconView
    ///     column view    AXList      no identifier at all
    ///     gallery view   AXList      id GalleryView
    ///     the desktop    AXGroup     no window in sight
    ///
    /// **The identifier is checked for outlines and only for outlines**, and
    /// that is the sidebar's fault. The sidebar is an `AXOutline` inside an
    /// `AXScrollArea` too, so nothing about its shape separates it from the
    /// list view, and ⌘⌫ there removes a favourite rather than moving a file.
    /// `AXDescription` looked like the way out until it was measured in a
    /// German Finder, where "sidebar" is "Seitenleiste" and "list view" is
    /// "Listendarstellung": it is localized, so a rule built on it would work
    /// here and quietly stop working abroad. `AXIdentifier` is not localized;
    /// the same Finder reports `ListView` and `_NS:8` in both languages.
    ///
    /// If a future macOS renames that identifier, list view stops being
    /// recognised and ⌫ goes back to doing nothing there, which is the failure
    /// this whole file is arranged to prefer.
    static func surface(_ app: AXUIElement) -> FinderSurface {
        guard let focused = copyElement(app, kAXFocusedUIElementAttribute),
              let role = copyString(focused, kAXRoleAttribute)
        else { return .unknown }

        if role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole {
            return .text
        }
        guard role == kAXOutlineRole || role == kAXListRole || role == kAXGroupRole
        else { return .unknown }
        if role == kAXOutlineRole, copyString(focused, axIdentifier) != fileListIdentifier {
            return .unknown
        }
        guard let parent = copyElement(focused, kAXParentAttribute),
              copyString(parent, kAXRoleAttribute) == kAXScrollAreaRole
        else { return .unknown }
        return .fileList
    }

    /// Not in the SDK's constants, and spelled here once rather than at the
    /// call site so a typo is a compile-time concern rather than a silent
    /// "no identifier".
    private static let axIdentifier = "AXIdentifier"

    /// Finder's own name for the list view's outline, in every language.
    private static let fileListIdentifier = "ListView"

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
