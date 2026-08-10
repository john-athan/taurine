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

    Check.suite("classify: a cancelled gesture is still a gesture") {
        // Phase 8 is kCGScrollPhaseCancelled. It is not in the set observed on
        // the trackpad here, but CoreGraphics defines it, and a drag that gets
        // cancelled must not turn into a wheel click halfway through.
        let d = ScrollDevice.classify(.init(isContinuous: true, phase: 8, momentumPhase: 0))
        Check.equal(d, .continuousSurface, "phase 8 cancelled is a surface")
    }

    Check.suite("classify: a wheel mouse") {
        let d = ScrollDevice.classify(.init(isContinuous: false, phase: 0, momentumPhase: 0))
        Check.equal(d, .wheel, "no continuity, no phase, no momentum")
    }

    Check.suite("classify: a mouse behind a vendor driver reads as a surface") {
        // Not an aspiration, a known limitation, pinned so it cannot change
        // without somebody noticing. Logitech Options rewrites a wheel mouse's
        // scroll events to be continuous, which is why UnnaturalScrollWheels
        // added a second detection mode, and Mos special-cases the Logitech
        // daemon by process id for the same reason. An event shaped like this
        // is indistinguishable from a trackpad in the only three fields this
        // classifier reads, so it is classified as a surface and never
        // corrected. ADR 0004 records the evidence, what the user sees, and
        // what they can do about it.
        let vendorDriven = ScrollTraits(isContinuous: true, phase: 2, momentumPhase: 0)
        Check.equal(ScrollDevice.classify(vendorDriven), .continuousSurface,
                    "a wheel mouse behind a vendor driver is not recognised as a wheel")
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
        let t = ScrollTraits.read(e)
        Check.that(t.isContinuous, "pixel events are continuous")
        Check.equal(t.phase, 2, "phase comes back as written")
        Check.equal(t.momentumPhase, 0, "no momentum on a phase event")
        Check.equal(ScrollDevice.classify(t), .continuousSurface, "and it classifies as a surface")

        let wheel = lineEvent(clicks: 1)
        Check.equal(ScrollDevice.classify(ScrollTraits.read(wheel)), .wheel, "a line event is a wheel")
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

    Check.suite("policy: exactly one class is corrected, and it is written down which") {
        // The expected answer is a table here, not a second call to the function
        // under test. Deriving it from `mustNegate` would agree with any
        // implementation at all, including one that corrects the wrong class.
        let expected: [(natural: Bool, corrected: [ScrollDevice])] = [
            (natural: true,  corrected: [.wheel]),
            (natural: false, corrected: [.continuousSurface]),
        ]
        for row in expected {
            let corrected = [ScrollDevice.continuousSurface, .wheel]
                .filter { ScrollCorrection.mustNegate($0, systemScrollsNaturally: row.natural) }
            Check.equal(corrected, row.corrected,
                        "natural == \(row.natural) corrects exactly \(row.corrected)")
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
        Check.equal(ScrollDevice.classify(ScrollTraits.read(e)), .continuousSurface,
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

        Check.equal(fixer.setEnabled(false), .off, "switching off returns to off")
        Check.that(!fixer.isEnabled, "and the choice is persisted")
        Check.isNil(fixer.explanation, "with nothing left to complain about")
    }

    Check.suite("fixer: starting again does not arm a second tap") {
        // The status is not the observable here. `start()` returning the same
        // `Status` is true of an implementation that arms a fresh tap on a fresh
        // thread every call, so the thread itself is what gets watched, by
        // identity rather than by count: a `start()` that tore the tap down and
        // rebuilt it would keep the count at one and still be wrong.
        let fixer = ScrollDirectionFixer(defaults: scratchDefaults(), key: "fixScrollDirection")
        let first = fixer.setEnabled(true)
        let armed = liveTapThreadIDs()

        if ScrollPermission.isGranted {
            Check.equal(armed.count, 1, "granted: exactly one tap thread is running")
        } else {
            Check.equal(armed.count, 0, "not granted: no tap thread is ever started")
        }

        Check.equal(fixer.start(), first, "the second start reports the same status")
        Check.equal(fixer.start(), first, "and so does the third")
        Check.equal(liveTapThreadIDs(), armed,
                    "and the tap thread is the same one: none added, none replaced")

        fixer.setEnabled(false)
    }

    Check.suite("fixer: stop() joins the tap thread, so threads never pile up") {
        // Asserting `status == .off` proves nothing on its own, because
        // `settle(.off)` sets it unconditionally whether or not a thread is
        // still running behind it. What `stop()` actually promises is that it
        // does not return while the tap thread can still run the callback,
        // which it keeps by joining.
        //
        // The bound is one rather than zero on purpose, and the reason is worth
        // knowing: the join waits for the thread to leave its run loop and drop
        // the tap source, which is the whole of the safety property, but the
        // kernel may still be reaping that pthread for a few microseconds
        // afterwards. Taurine promises nothing about reaping. Eight is the
        // number this catches: without the join all eight of these are still
        // running their run loops at this point, which is exactly what the
        // teardown this replaced did.
        var fixers: [ScrollDirectionFixer] = []
        for _ in 0..<8 {
            let f = ScrollDirectionFixer(defaults: scratchDefaults(), key: "fixScrollDirection")
            f.setEnabled(true)
            f.stop()
            Check.equal(f.status, .off, "each one reports itself off")
            fixers.append(f)
        }
        Check.that(liveTapThreadIDs().count <= 1,
                   "eight armed and stopped back to back leave no pile of live tap threads "
                 + "(saw \(liveTapThreadIDs().count))")
        for f in fixers { f.setEnabled(false) }
    }

    Check.suite("fixer: taking the tap down is not counted as a re-arm") {
        // Disabling a tap makes macOS deliver one last callback on the tap
        // thread, every time, and that callback's job is to re-arm whatever tap
        // it finds. Before the teardown was ordered to prevent it, 400 clean
        // cycles here produced a re-arm count in the tens, and the tooltip
        // blamed macOS for something Taurine had done to itself.
        let fixer = ScrollDirectionFixer(defaults: scratchDefaults(), key: "fixScrollDirection")
        for _ in 0..<40 {
            fixer.setEnabled(true)
            fixer.setEnabled(false)
        }
        Check.equal(fixer.reArmCount, 0, "40 clean start/stop cycles are not a fault to report")
        Check.equal(liveTapThreadIDs(), [], "and leave no tap thread behind")

        fixer.setEnabled(true)
        Check.that(!fixer.tooltip.contains("Re-armed"), "so the tooltip invents no problem")
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

// MARK: - watching the tap thread

/// The thread ids of every live scroll tap thread in this process.
///
/// The tap thread is the only outward sign that a tap exists, so it is what the
/// lifecycle tests observe. Ids rather than a count, because "starting twice
/// does not arm a second tap" and "there is one tap thread" are different
/// claims, and only the first one is the promise being made.
private func liveTapThreadIDs() -> Set<UInt64> {
    var ports: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &ports, &count) == KERN_SUCCESS, let ports else { return [] }
    defer {
        for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, ports[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: ports)),
                      vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
    }

    var found: Set<UInt64> = []
    for i in 0..<Int(count) where threadName(ports[i]).contains("taurine.scroll") {
        if let id = threadID(ports[i]) { found.insert(id) }
    }
    return found
}

/// The name `Thread.name` put on the underlying pthread, or "" if it has none.
private func threadName(_ port: thread_act_t) -> String {
    var info = thread_extended_info_data_t()
    var size = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size
                                      / MemoryLayout<natural_t>.size)
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            thread_info(port, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &size)
        }
    }
    guard ok == KERN_SUCCESS else { return "" }
    return withUnsafeBytes(of: &info.pth_name) {
        String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
    }
}

/// The kernel's unique id for a thread. Unlike the mach port name it is never
/// recycled, so a rebuilt tap thread is always distinguishable from a kept one.
private func threadID(_ port: thread_act_t) -> UInt64? {
    var info = thread_identifier_info_data_t()
    var size = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size
                                      / MemoryLayout<natural_t>.size)
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            thread_info(port, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &size)
        }
    }
    return ok == KERN_SUCCESS ? info.thread_id : nil
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
