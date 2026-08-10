import Foundation

/// The memory of a cut, and the pasteboard arithmetic that keeps it honest. 🧾
///
/// A cut is a promise about the *next* ⌘V, made a second or a minute earlier,
/// and the danger is entirely in that gap. If Taurine remembers a cut that the
/// pasteboard no longer holds, ⌘V moves the wrong files, which is the one way
/// this feature could cost somebody something. So the memory is not "the user
/// pressed ⌘X"; it is three numbers that can be checked against the pasteboard
/// at the moment of the paste.
///
/// The pasteboard's change count is a counter that goes up by one every time any
/// process puts anything on the general pasteboard. Sampling it around the cut
/// pins the exact pasteboard the cut produced:
///
///     before   the count just before Finder was let at the rewritten ⌘X
///     pending  the count right after it copied, which identifies our pasteboard
///     now      the count when ⌘V arrives
///
/// `pending == now` is the whole test, and it is false the instant anything
/// copies anything anywhere, which is exactly when the promise should expire.
///
/// `awaitingCopy` covers the gap in that: Finder is asked to copy, the key comes
/// back up perhaps eighty milliseconds later, and the copy has not landed. That
/// is not the rare case, it is every measured case. Rather than declare the cut
/// dead, the ledger keeps it claimable until a copy lands and pins it to that
/// pasteboard the first time it looks, so the loose claim covers a keystroke or
/// two rather than the whole life of the cut. The ⌘C rule in `FinderCutPolicy`
/// is what stops the claim from stealing somebody else's copy: a copy typed in
/// Finder forgets the cut before its pasteboard ever exists.
///
/// The remaining hole is written down rather than papered over: while a cut is
/// awaiting its copy, a *background* application that writes the pasteboard
/// (a clipboard manager, a script) can be mistaken for Finder's copy, and the
/// next ⌘V would move the cut files instead of pasting. Three things have to
/// coincide for it: a Finder too busy to copy for the length of a keypress or a
/// ⌘X that selected nothing, another process writing files to the pasteboard
/// before the next keystroke in Finder, and no paste and no application switch
/// in between, either of which settles the claim. See ADR 6.
enum FinderCutLedger {

    /// Whether there is anything at all to check. Cheap, and it is what lets the
    /// tap skip asking the pasteboard anything for every keystroke that is not
    /// part of a cut and paste.
    static func hasCut(_ cut: PendingCut) -> Bool { cut.pending >= 0 || cut.awaitingCopy }

    /// Whether the pasteboard is still the one the cut put there.
    static func isPending(_ cut: PendingCut, changeCount now: Int64) -> Bool {
        if cut.pending >= 0 { return cut.pending == now }
        if cut.awaitingCopy { return now != cut.before }
        return false
    }

    /// Nail a waiting claim down to the pasteboard that turned up under it.
    ///
    /// A claim that is still waiting is the loose kind: it says "a copy has not
    /// landed yet, so take the next one as mine". The moment a count is seen
    /// that is not the one the cut started from, that copy has landed and the
    /// cut can name it exactly, after which nothing else can ever be mistaken
    /// for it. So this is called on every reading of the pasteboard, and not
    /// only on the key-up of the cut.
    ///
    /// That is not a refinement, it is the difference between the exact rule and
    /// the loose one being the normal path. Measured against a real Finder, the
    /// key-up sample was too early every single time: the copy lands after the
    /// key comes back up, so the cut was never pinned there and every later
    /// decision was made on the loose claim.
    ///
    /// A count that has *not* moved is left alone rather than given up on,
    /// because Finder being slow and Finder having copied nothing look identical
    /// from here. Giving up on that is `resolve`'s job, and it has the one piece
    /// of information that separates them: that the user has left Finder.
    static func pin(_ cut: PendingCut, changeCount now: Int64) -> PendingCut {
        guard cut.awaitingCopy, now != cut.before else { return cut }
        return PendingCut(before: cut.before, pending: now, awaitingCopy: false)
    }

    /// Settle a claim that is still waiting for its copy, at the moment we stop
    /// watching Finder.
    ///
    /// While Finder is frontmost, "waiting for a copy" is a reasonable thing to
    /// be: Finder was asked to copy and may not have finished. The moment
    /// something else comes forward that stops being reasonable, because a copy
    /// landing after that is somebody else's. So the claim is turned into an
    /// answer here rather than carried: either a copy did land, and the cut is
    /// pinned to the exact pasteboard it produced, or none did, and there was
    /// never a cut to remember.
    ///
    /// This is what keeps a ⌘X that copied nothing from following the user
    /// around: after it, no fuzzy claim survives an application switch.
    static func resolve(_ cut: PendingCut, changeCount now: Int64) -> PendingCut {
        guard cut.awaitingCopy else { return cut }
        return now != cut.before ? pin(cut, changeCount: now) : .nothingPending
    }

    /// How an action moves the ledger. Pure, total, and the only place these
    /// three numbers are written.
    static func after(_ action: FinderKeyAction, isDown: Bool,
                      cut: PendingCut, changeCount now: Int64) -> PendingCut {
        switch action {
        case .passThrough:
            return cut

        case .copyInstead where isDown:
            // Finder has not seen the ⌘C this became, so `now` is the count its
            // copy is about to move past. Any older cut is dropped here: the new
            // ⌘X replaces it, whether or not it ever copied anything.
            return PendingCut(before: now, pending: -1, awaitingCopy: true)

        case .copyInstead:
            // The key-up. A count that has moved is Finder's copy, and it names
            // the pasteboard this cut owns. A count that has not moved means
            // Finder is still busy or nothing was selected; either way the cut
            // stays claimable and the next check decides.
            return now != cut.before
                ? PendingCut(before: cut.before, pending: now, awaitingCopy: false)
                : cut

        case .moveInstead:
            // Deliberately unchanged. A cut lasts exactly as long as the
            // pasteboard it pinned, and pasting does not change the pasteboard.
            //
            // Spending it here was the first version, and it was wrong in a way
            // a user found in a minute: move a file, press ⌘Z to undo the move,
            // press ⌘V again, and the second paste was an ordinary one, so the
            // file was copied and ended up in both folders. Nothing about the
            // pasteboard had changed between those two pastes, so nothing about
            // the cut should have.
            return cut

        case .forgetTheCut:
            return .nothingPending
        }
    }
}

/// The three numbers, in a form both threads can hold.
///
/// Plain scalars with no references in them, so a copy can live in the cell the
/// tap callback reads without any ARC traffic, and the same value can be handed
/// back to the owner when the tap is taken down. Taps come and go with every
/// application switch; a cut made in Finder, followed by a trip to a browser and
/// back, has to survive that.
struct PendingCut: Equatable {

    /// The change count sampled just before the cut's copy was let through.
    var before: Int64

    /// The change count of the pasteboard this cut owns, or -1 if that
    /// pasteboard has not been seen yet. Change counts are never negative, so -1
    /// is the natural empty value.
    var pending: Int64

    /// True while a cut has been made but no copy has landed for it yet.
    var awaitingCopy: Bool

    static let nothingPending = PendingCut(before: -1, pending: -1, awaitingCopy: false)
}
