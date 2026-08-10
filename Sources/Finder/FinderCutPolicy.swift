import Carbon.HIToolbox
import CoreGraphics

/// The verdict. ✂️
///
/// Finder has always had the *move* half of cut and paste. It is called "Move
/// Item Here", it lives in the Edit menu behind the Option key, and it works on
/// whatever the last Copy put on the pasteboard. What Finder does not have is
/// the pair of keystrokes everybody's hands already know, so this fix does not
/// implement moving files at all. It rewrites two keystrokes into the two
/// Finder already answers:
///
///     ⌘X  →  ⌘C     copy, and remember that a cut is pending
///     ⌘V  →  ⌥⌘V    Move Item Here, if that cut is still the pasteboard
///
/// Finder does the work, which is the whole point: the progress sheet, the
/// "an item with that name already exists" dialog, the authentication prompt for
/// a folder you do not own, and Undo all come from Finder, because from Finder's
/// side nothing unusual has happened. Taurine copies no file and deletes no
/// file. It cannot lose your data because it never handles it.
///
/// The rewrite is done to the event in place, in the same style as the scroll
/// fix: no keystroke is swallowed and none is synthesised, so there is no
/// synthetic event to feed back into our own tap and no unmatched key-up left
/// behind. Key-down and key-up are rewritten alike, so an application sees a
/// balanced ⌘C press even though a ⌘X was typed.
///
/// **Why a character *and* a key code.** A key code is a position on the
/// keyboard; a character is what that position produces under the layout in
/// force. Rewriting X into C is only meaningful when the two agree, which they
/// do on QWERTY, QWERTZ, AZERTY and Colemak, all of which keep ZXCV where IBM
/// put them, and on "Dvorak - Qwerty ⌘", which restores those positions while
/// Command is held for exactly this reason. Requiring both to match means that
/// on a layout where they disagree (plain Dvorak, most obviously) the rule does
/// not fire and the feature does nothing, rather than firing and sending Finder
/// a keystroke nobody pressed.
enum FinderCutPolicy {

    /// What to do about one keystroke. Pure, and the only place the rule lives.
    ///
    /// `editingText` is what keeps this out of the way of renaming a file: in a
    /// text field ⌘X really does mean cut this text, and Finder handles it
    /// perfectly well, so nothing here applies. `cutIsPending` is the caller's
    /// answer to "is the pasteboard still the one our cut put there", which
    /// needs the pasteboard and so cannot be decided in here.
    static func decide(_ key: KeyPress, editingText: Bool, cutIsPending: Bool) -> FinderKeyAction {
        guard !editingText else { return .passThrough }

        // The cut itself. Rewritten on the way down and on the way up, so the
        // press an application sees is a balanced one.
        if key.chord == .command, key.is("x", kVK_ANSI_X) { return .copyInstead }

        guard key.isDown else { return .passThrough }

        // A real copy replaces a pending cut, and it does so whether or not the
        // cut looks pending at this instant. The instant matters: Finder has not
        // handled this ⌘C yet, so the pasteboard still holds the cut, and a rule
        // that asked "is a cut pending" here would answer yes, forget nothing,
        // and later move the files this copy is about to put on the pasteboard.
        if key.chord == .command, key.is("c", kVK_ANSI_C) { return .forgetTheCut }

        // Somebody who knows about ⌥⌘V and used it has done the move themselves.
        if key.chord == .commandOption, key.is("v", kVK_ANSI_V) { return .forgetTheCut }

        // Escape means "never mind", the way it does in the file manager this
        // muscle memory comes from.
        if key.chord == .bare, key.keyCode == Int64(kVK_Escape) { return .forgetTheCut }

        // The paste. A cut that is no longer the pasteboard does not become one
        // again, so a paste ends it either way: it moves the files if the cut is
        // still good, and otherwise it is an ordinary paste that clears the cut
        // out of the way. That second half is not tidiness. A ⌘X that copied
        // nothing (nothing was selected) leaves a claim outstanding, and without
        // this the claim would sit there until something else copied a file,
        // which the next ⌘V would then move.
        if key.chord == .command, key.is("v", kVK_ANSI_V) {
            return cutIsPending ? .moveInstead : .forgetTheCut
        }

        return .passThrough
    }

    /// Carry out a decision on the event itself. Separate from `decide` so the
    /// rule can be tested without an event and the rewrite can be tested without
    /// a pasteboard, and because this is the only code in Taurine that changes
    /// what key an application thinks you pressed.
    static func apply(_ action: FinderKeyAction, to event: CGEvent) {
        switch action {
        case .passThrough, .forgetTheCut:
            return

        case .copyInstead:
            // The key code, and *only* the key code.
            //
            // Also writing the event's Unicode string looks like the more
            // thorough rewrite, since that is where `NSEvent.characters` comes
            // from, and it is the version this was first written as. It does not
            // work: setting the string stops Finder matching the Edit menu's
            // equivalent at all, and the keystroke does nothing whatsoever.
            // Measured against a real Finder on macOS 26, three runs, one dummy
            // file, the pasteboard's change count as the verdict: key code alone
            // copied every time, key code plus string copied none of the six
            // times it was tried in either order. There is no partial failure
            // here to debug later, which is the danger: it looks like the fix is
            // simply switched off.
            //
            // Nothing is lost by leaving the string behind. It goes on saying
            // "x", and AppKit pays it no attention: `charactersIgnoringModifiers`,
            // which is what a menu equivalent is matched against, is derived from
            // the key code and says "c" the moment the key code does.
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_ANSI_C))

        case .moveInstead:
            // The Option key is not down. Menu key-equivalent matching reads the
            // event's flags, not the state of the physical keyboard, so this is
            // the whole of turning Paste into Move Item Here.
            event.flags.insert(.maskAlternate)
        }
    }
}

/// The four answers, in the order the rule considers them.
enum FinderKeyAction: Equatable {

    /// Not ours. The event goes to Finder exactly as it arrived.
    case passThrough

    /// ⌘X becomes ⌘C, and a cut is now pending.
    case copyInstead

    /// ⌘V becomes ⌥⌘V, and the pending cut is spent.
    case moveInstead

    /// Passed through untouched, but whatever cut was pending no longer is.
    case forgetTheCut
}

/// One keystroke, reduced to the four things the rule is allowed to look at.
///
/// Split out from `CGEvent` so the decision can be tested over keystrokes and
/// layouts this machine cannot produce, and so the tap callback reads a fixed,
/// countable set of fields.
struct KeyPress: Equatable {

    /// The physical key, as `kVK_ANSI_X` and friends name it.
    let keyCode: Int64

    /// What that key produces under the current layout, or nil if the event
    /// carries no character at all. Read with Command held, where macOS reports
    /// the unmodified character.
    let character: UnicodeScalar?

    /// False for a key-up. A cut is armed on the way up, so the two are not
    /// interchangeable.
    let isDown: Bool

    let chord: Chord

    init(keyCode: Int64, character: UnicodeScalar?, isDown: Bool, chord: Chord) {
        self.keyCode = keyCode
        self.character = character
        self.isDown = isDown
        self.chord = chord
    }

    /// Both halves have to agree. See the note on layouts in `FinderCutPolicy`.
    func `is`(_ character: UnicodeScalar, _ keyCode: Int) -> Bool {
        self.keyCode == Int64(keyCode) && self.character == character
    }

    /// Read off a live event, on the tap thread.
    ///
    /// The character is fetched into a stack buffer and compared as a scalar, so
    /// nothing here allocates a `String`: this runs for every ⌘X, ⌘C, ⌘V and
    /// Escape typed in Finder, and while none of those is a hot path, a heap
    /// allocation on a tap thread is a habit worth not having.
    static func read(_ event: CGEvent) -> KeyPress {
        var length = 0
        var buffer = UniChar(0)
        event.keyboardGetUnicodeString(maxStringLength: 1,
                                       actualStringLength: &length,
                                       unicodeString: &buffer)
        return KeyPress(keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                        character: length == 1 ? UnicodeScalar(buffer) : nil,
                        isDown: event.type == .keyDown,
                        chord: Chord(event.flags))
    }
}

/// The modifiers, as a set of exactly four, compared by value.
///
/// Caps Lock, Fn, the numeric-pad bit and the left/right device bits are all
/// deliberately not here. They ride along on ordinary keystrokes (Fn is set on
/// every key of some keyboards), and a rule written against raw
/// `CGEventFlags` equality would silently stop working for the people whose
/// hardware sets them.
struct Chord: Equatable {
    let command, option, control, shift: Bool

    init(command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false) {
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    init(_ flags: CGEventFlags) {
        self.init(command: flags.contains(.maskCommand),
                  option: flags.contains(.maskAlternate),
                  control: flags.contains(.maskControl),
                  shift: flags.contains(.maskShift))
    }

    /// No modifier at all.
    static let bare = Chord()

    /// Command and nothing else. ⇧⌘X and ⌃⌘X are somebody else's shortcuts.
    static let command = Chord(command: true)

    /// Command and Option: Finder's own Move Item Here.
    static let commandOption = Chord(command: true, option: true)
}
