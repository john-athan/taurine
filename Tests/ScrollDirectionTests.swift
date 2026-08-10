import AppKit
import CoreGraphics
import Foundation

/// Scroll events, real shapes and impossible ones.
///
/// Two thirds of this file needs no permission and no hardware, because the two
/// decisions (what device is this, does it need flipping) are pure functions and
/// the flip itself can be done to an event built with
/// `CGEvent(scrollWheelEvent2Source:)` and read straight back. The event shapes
/// used here are copied from a real Apple trackpad, captured with a listen-only
/// tap: a slow drag really does send pixel deltas with a line delta of zero, and
/// that is the case that breaks a naive implementation.
///
/// The last few suites drive a real `ScrollDirectionFixer`. If the test binary
/// happens to have inherited Accessibility permission from the terminal that ran
/// it, those suites arm a genuine event tap for the fraction of a millisecond it
/// takes to assert and take it down again, which is the only way the thread and
/// run loop teardown ever gets exercised. They assert the honest answer either
/// way, so the run passes with the permission and without it.
func runScrollDirectionTests() {

    // MARK: - the classifier

    Check.suite("classify: an Apple trackpad, one gesture start to finish") {
        // phase 1 began, 2 changed, 4 ended, 128 may-begin: all observed.
        for phase in [Int64(1), 2, 4, 128] {
            let d = ScrollDevice.classify(.init(isContinuous: true, phase: phase, momentumPhase: 0))
            Check.equal(d, .continuousSurface, "phase \(phase) is a surface")
        }
    }

    Check.suite("classify: the momentum tail after the fingers lift") {
        // Momentum events carry phase 0 and momentum 1/2/3. Getting these wrong
        // would reverse the page at the exact moment you let go.
        for momentum in [Int64(1), 2, 3] {
            let d = ScrollDevice.classify(.init(isContinuous: true, phase: 0, momentumPhase: momentum))
            Check.equal(d, .continuousSurface, "momentum \(momentum) is a surface")
        }
    }

    Check.suite("classify: a wheel mouse") {
        let d = ScrollDevice.classify(.init(isContinuous: false, phase: 0, momentumPhase: 0))
        Check.equal(d, .wheel, "no continuity, no phase, no momentum")
    }

    Check.suite("classify: a Magic Mouse is a mouse and still a surface") {
        // It reports continuity and phase like a trackpad. The point of
        // classifying the event rather than the device is that this needs no
        // special case at all.
        let d = ScrollDevice.classify(.init(isContinuous: true, phase: 2, momentumPhase: 0))
        Check.equal(d, .continuousSurface, "continuous mouse follows the trackpad rule")
    }

    Check.suite("classify: any one signal is enough") {
        Check.equal(ScrollDevice.classify(.init(isContinuous: false, phase: 2, momentumPhase: 0)),
                    .continuousSurface, "phase alone")
        Check.equal(ScrollDevice.classify(.init(isContinuous: false, phase: 0, momentumPhase: 2)),
                    .continuousSurface, "momentum alone")
        Check.equal(ScrollDevice.classify(.init(isContinuous: true, phase: 0, momentumPhase: 0)),
                    .continuousSurface, "continuity alone")
    }

    Check.suite("classify: read off a live event") {
        let e = pixelEvent(vertical: 10, horizontal: 0, phase: 2)
        let t = ScrollTraits(of: e)
        Check.that(t.isContinuous, "pixel events are continuous")
        Check.equal(t.phase, 2, "phase comes back as written")
        Check.equal(t.momentumPhase, 0, "no momentum on a phase event")
        Check.equal(ScrollDevice.classify(t), .continuousSurface, "and it classifies as a surface")

        let wheel = lineEvent(clicks: 1)
        Check.equal(ScrollDevice.classify(ScrollTraits(of: wheel)), .wheel, "a line event is a wheel")
    }

    // MARK: - the policy, exhaustively

    Check.suite("policy: the whole matrix") {
        Check.that(!ScrollCorrection.mustNegate(.continuousSurface, systemScrollsNaturally: true),
                   "natural system, surface: already right")
        Check.that(ScrollCorrection.mustNegate(.wheel, systemScrollsNaturally: true),
                   "natural system, wheel: reversed")
        Check.that(ScrollCorrection.mustNegate(.continuousSurface, systemScrollsNaturally: false),
                   "traditional system, surface: reversed")
        Check.that(!ScrollCorrection.mustNegate(.wheel, systemScrollsNaturally: false),
                   "traditional system, wheel: already right")
    }

    Check.suite("policy: exactly one class is ever corrected") {
        for natural in [true, false] {
            let corrected = [ScrollDevice.continuousSurface, .wheel]
                .filter { ScrollCorrection.mustNegate($0, systemScrollsNaturally: natural) }
            Check.equal(corrected.count, 1, "one class corrected when natural == \(natural)")
        }
    }

    // MARK: - reading the system setting

    Check.suite("system setting: the values people actually leave behind") {
        Check.that(SystemScrollDirection.interpret(nil),
                   "absent means natural, which is how a Mac ships")
        Check.that(!SystemScrollDirection.interpret(kCFBooleanFalse),
                   "a real boolean false")
        Check.that(SystemScrollDirection.interpret(kCFBooleanTrue),
                   "a real boolean true")
        Check.that(!SystemScrollDirection.interpret(NSNumber(value: 0)),
                   "defaults write -int 0")
        Check.that(SystemScrollDirection.interpret(NSNumber(value: 1)),
                   "defaults write -int 1")
        Check.that(!SystemScrollDirection.interpret("NO" as CFString),
                   "defaults write -string NO")
        Check.that(SystemScrollDirection.interpret([1, 2] as CFArray),
                   "nonsense falls back to natural rather than to off")
    }

    // MARK: - the flip, on real events

    Check.suite("flip: a pixel event keeps every unit in step") {
        let e = pixelEvent(vertical: 30, horizontal: 12, phase: 2)
        let before = Deltas(e)
        ScrollCorrection.negateDeltas(of: e)
        let after = Deltas(e)
        Check.equal(after.line1, -before.line1, "vertical line delta")
        Check.equal(after.line2, -before.line2, "horizontal line delta")
        Check.close(after.fixed1, -before.fixed1, tolerance: 0.0001, "vertical fixed-point delta")
        Check.close(after.fixed2, -before.fixed2, tolerance: 0.0001, "horizontal fixed-point delta")
        Check.equal(after.point1, -before.point1, "vertical pixel delta")
        Check.equal(after.point2, -before.point2, "horizontal pixel delta")
        Check.equal(after.point1, -30, "and the magnitude is the one we started with")
    }

    Check.suite("flip: a slow drag, pixels only, no line delta") {
        // The trap. Writing the line delta rewrites the pixel delta on the same
        // axis, so negating a zero line delta zeroes the pixels and the page
        // stops moving. Most of a real trackpad gesture looks like this.
        let e = pixelOnlyEvent(vertical: 1)
        Check.equal(e.getIntegerValueField(.scrollWheelEventDeltaAxis1), 0,
                    "the shape under test really has a zero line delta")
        Check.close(e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), 0, tolerance: 0.0001,
                    "and a zero fixed-point delta")
        Check.equal(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 1,
                    "and one pixel of movement")
        ScrollCorrection.negateDeltas(of: e)
        Check.equal(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -1,
                    "the pixel survives the flip, reversed")
        Check.equal(e.getIntegerValueField(.scrollWheelEventDeltaAxis1), 0,
                    "and the line delta is still zero")
    }

    Check.suite("flip: a wheel click, lines only, no pixels") {
        let e = lineEvent(clicks: 3)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        let before = Deltas(e)
        Check.equal(before.line1, 3, "three clicks")
        Check.equal(before.point1, 0, "and no pixel component")
        ScrollCorrection.negateDeltas(of: e)
        let after = Deltas(e)
        Check.equal(after.line1, -3, "clicks reversed")
        Check.close(after.fixed1, -before.fixed1, tolerance: 0.0001, "fixed-point follows")
        Check.equal(after.point1, 0, "a zero pixel delta is not invented into a number")
    }

    Check.suite("flip: momentum keeps its direction with the gesture") {
        let e = momentumEvent(vertical: 11)
        Check.equal(ScrollDevice.classify(ScrollTraits(of: e)), .continuousSurface,
                    "a momentum event is a surface")
        ScrollCorrection.apply(to: e, systemScrollsNaturally: false)
        Check.equal(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -11,
                    "reversed under a traditional system, same as the gesture that threw it")
        ScrollCorrection.apply(to: e, systemScrollsNaturally: true)
        Check.equal(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -11,
                    "and left alone under a natural one")
    }

    Check.suite("flip: horizontal scrolling with shift held") {
        // Shift-to-scroll-sideways is done above us, by AppKit, from the same
        // axis-1 delta. Both axes are reversed together and the modifier flags
        // are not ours to touch, so the swap stays coherent either way.
        let e = pixelEvent(vertical: 20, horizontal: 0, phase: 2)
        e.flags = .maskShift
        ScrollCorrection.apply(to: e, systemScrollsNaturally: false)
        Check.equal(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -20,
                    "the axis the modifier will redirect is reversed")
        Check.equal(e.flags.rawValue, CGEventFlags.maskShift.rawValue,
                    "and the modifier is passed through untouched")
    }

    Check.suite("flip: twice is a no-op") {
        let e = pixelEvent(vertical: 7, horizontal: -3, phase: 2)
        let before = Deltas(e)
        ScrollCorrection.negateDeltas(of: e)
        ScrollCorrection.negateDeltas(of: e)
        let after = Deltas(e)
        Check.equal(after.line1, before.line1, "line axis 1 restored")
        Check.equal(after.line2, before.line2, "line axis 2 restored")
        Check.close(after.fixed1, before.fixed1, tolerance: 0.0001, "fixed axis 1 restored")
        Check.close(after.fixed2, before.fixed2, tolerance: 0.0001, "fixed axis 2 restored")
        Check.equal(after.point1, before.point1, "pixel axis 1 restored")
        Check.equal(after.point2, before.point2, "pixel axis 2 restored")
    }

    Check.suite("flip: a phase-ended event carries nothing and stays nothing") {
        let e = pixelEvent(vertical: 0, horizontal: 0, phase: 4)
        ScrollCorrection.apply(to: e, systemScrollsNaturally: false)
        Check.equal(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0, "still zero")
        Check.equal(e.getIntegerValueField(.scrollWheelEventDeltaAxis1), 0, "still zero")
    }

    Check.suite("flip: what an application actually receives") {
        // The last word on whether the right fields were flipped is AppKit's,
        // since that is what applications read. `deltaY` comes from the
        // fixed-point field; `scrollingDeltaY` comes from the pixel field on a
        // continuous event and the fixed-point field on a discrete one. Every
        // one of those has to change sign, or something on screen disagrees
        // with something else on screen.
        let drag = pixelOnlyEvent(vertical: 12)
        Check.that(NSEvent(cgEvent: drag)?.hasPreciseScrollingDeltas == true,
                   "a pixel-only event arrives as a precise one")
        ScrollCorrection.negateDeltas(of: drag)
        if let after = Check.unwrap(NSEvent(cgEvent: drag), "the flipped event is still an NSEvent") {
            Check.close(after.scrollingDeltaY, -12, tolerance: 0.0001,
                        "a precise scroll of 12 pixels arrives as minus 12")
        }

        let click = lineEvent(clicks: 3)
        ScrollCorrection.negateDeltas(of: click)
        if let after = Check.unwrap(NSEvent(cgEvent: click), "the flipped click is still an NSEvent") {
            Check.close(after.deltaY, -3, tolerance: 0.0001, "three clicks arrive as minus three")
            Check.close(after.scrollingDeltaY, -3, tolerance: 0.0001, "and so does the modern accessor")
            Check.that(!after.hasPreciseScrollingDeltas, "a wheel click stays imprecise")
        }
    }

    // MARK: - end to end, both settings, one event shape

    Check.suite("apply: the system setting changes mid-session") {
        // The same trackpad event, under each setting, with no state in between:
        // this is what happens when somebody flips the checkbox in System
        // Settings while Taurine is running.
        let natural = pixelEvent(vertical: 9, horizontal: 0, phase: 2)
        ScrollCorrection.apply(to: natural, systemScrollsNaturally: true)
        Check.equal(natural.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 9,
                    "natural system: the trackpad is left alone")

        let traditional = pixelEvent(vertical: 9, horizontal: 0, phase: 2)
        ScrollCorrection.apply(to: traditional, systemScrollsNaturally: false)
        Check.equal(traditional.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -9,
                    "traditional system: the same event is reversed")

        let wheelNatural = lineEvent(clicks: 2)
        ScrollCorrection.apply(to: wheelNatural, systemScrollsNaturally: true)
        Check.equal(wheelNatural.getIntegerValueField(.scrollWheelEventDeltaAxis1), -2,
                    "natural system: the wheel is reversed")

        let wheelTraditional = lineEvent(clicks: 2)
        ScrollCorrection.apply(to: wheelTraditional, systemScrollsNaturally: false)
        Check.equal(wheelTraditional.getIntegerValueField(.scrollWheelEventDeltaAxis1), 2,
                    "traditional system: the same wheel click is left alone")
    }

    // MARK: - the object

    Check.suite("fixer: off by default, and says nothing is wrong while off") {
        let fixer = ScrollDirectionFixer(defaults: scratchDefaults(), key: "fixScrollDirection")
        Check.that(!fixer.isEnabled, "a fresh install does not touch scroll events")
        Check.equal(fixer.status, .off, "and reports itself off")
        Check.isNil(fixer.explanation, "off is not a fault, so there is nothing to explain")
        Check.equal(fixer.reArmCount, 0, "nothing to re-arm")
        fixer.stop()
        Check.equal(fixer.status, .off, "stopping an already-stopped fixer is quiet")
    }

    Check.suite("fixer: switching on records the choice and reports honestly") {
        let store = scratchDefaults()
        let fixer = ScrollDirectionFixer(defaults: store, key: "fixScrollDirection")
        let status = fixer.setEnabled(true)
        Check.that(fixer.isEnabled, "the choice is persisted")
        Check.that(store.bool(forKey: "fixScrollDirection"), "in the store it was given")

        // The test binary is not the app bundle, so on a normal machine it has
        // no Accessibility grant and must say so rather than pretend.
        if ScrollPermission.isGranted {
            Check.that(status == .correcting(.wheel) || status == .correcting(.continuousSurface),
                       "granted: the tap is armed and one class is being corrected")
            Check.isNil(fixer.explanation, "and there is nothing to explain")
        } else {
            Check.equal(status, .needsPermission, "not granted: says so")
            Check.that(fixer.explanation?.contains("Accessibility") == true,
                       "and explains where to go")
            Check.that(fixer.label.contains("needs permission"), "the menu says it too")
        }

        Check.equal(fixer.start(), status, "starting twice does not arm a second tap")

        Check.equal(fixer.setEnabled(false), .off, "switching off returns to off")
        Check.that(!fixer.isEnabled, "and the choice is persisted")
        Check.isNil(fixer.explanation, "with nothing left to complain about")

        // The interesting half of the lifecycle: a tap that was really armed on
        // a run loop on its own thread has to come down again without hanging.
        fixer.setEnabled(true)
        fixer.stop()
        Check.equal(fixer.status, .off, "stop() takes the tap and its thread down and says so")
        fixer.setEnabled(false)
    }

    Check.suite("fixer: the tooltip always says something useful") {
        let fixer = ScrollDirectionFixer(defaults: scratchDefaults(), key: "fixScrollDirection")
        Check.that(fixer.tooltip.contains("naturally"), "off: describes what it would do")
        fixer.setEnabled(true)
        Check.that(!fixer.tooltip.isEmpty, "on: describes what it is doing, or what is wrong")
        fixer.setEnabled(false)
    }
}

// MARK: - event shapes

/// The six numbers a scroll event carries in three currencies.
private struct Deltas {
    let line1, line2, point1, point2: Int64
    let fixed1, fixed2: Double

    init(_ e: CGEvent) {
        line1 = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        line2 = e.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        fixed1 = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        fixed2 = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        point1 = e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        point2 = e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
    }
}

/// A trackpad-shaped event: pixel units, continuous, inside a gesture.
private func pixelEvent(vertical: Int32, horizontal: Int32, phase: Int64) -> CGEvent {
    let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                    wheel1: vertical, wheel2: horizontal, wheel3: 0)!
    e.setIntegerValueField(ScrollTraits.scrollPhase, value: phase)
    return e
}

/// The commonest shape a real trackpad sends, and the one a synthesizer will not
/// produce on its own: a pixel of movement with no line delta at all.
/// `CGEvent(scrollWheelEvent2Source:)` rounds any non-zero pixel count up to one
/// line, so the line delta has to be cleared afterwards, which is also a live
/// demonstration of the ordering rule: clearing it wipes the other two fields on
/// the axis, so they are written back after.
private func pixelOnlyEvent(vertical: Int64) -> CGEvent {
    let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                    wheel1: 1, wheel2: 0, wheel3: 0)!
    e.setIntegerValueField(ScrollTraits.scrollPhase, value: 2)
    e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
    e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
    e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: vertical)
    return e
}

/// The inertial tail: continuous, no phase, momentum instead.
private func momentumEvent(vertical: Int32) -> CGEvent {
    let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                    wheel1: vertical, wheel2: 0, wheel3: 0)!
    e.setIntegerValueField(ScrollTraits.momentumPhase, value: 2)
    return e
}

/// A wheel-shaped event: line units, not continuous, no phase.
private func lineEvent(clicks: Int32) -> CGEvent {
    CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
            wheel1: clicks, wheel2: 0, wheel3: 0)!
}

/// A preferences domain that is not the user's. Tests must be able to switch a
/// real `ScrollDirectionFixer` on and off without leaving anything behind.
private func scratchDefaults() -> UserDefaults {
    let suite = "io.github.john-athan.taurine.tests.scroll"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}
