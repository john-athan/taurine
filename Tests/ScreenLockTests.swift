import Foundation
import IOKit.pwr_mgt

/// Awake with the screen locked: the assertion arithmetic, and the reading of
/// the two settings that decide whether it behaves the way anyone expects.
///
/// Nothing here locks anything or spawns `pmset`. The two parts worth testing
/// are the parts that can be wrong quietly: which guards a session ends up
/// holding, and what a real `pmset -g` block means. The sample output below was
/// captured on this Mac (M4 Pro, macOS 26.5.2) rather than written from memory,
/// including the parenthetical that `pmset` appends while an assertion is held,
/// because that suffix sitting on the same line as the number is exactly the
/// shape a column-splitting parser gets wrong.
func runScreenLockTests() {

    Check.suite("guards: the default shape is unchanged") {
        Check.equal(AwakeShape.guards(letScreenLock: false, alsoSystemSleep: false),
                    [.display], "display only, the way it always was")
        Check.equal(AwakeShape.guards(letScreenLock: false, alsoSystemSleep: true),
                    [.display, .system], "and both when system sleep is opted into")
    }

    Check.suite("guards: letting the screen lock drops the display guard") {
        // This is the whole feature. Holding PreventUserIdleDisplaySleep is
        // what stops macOS ever turning the screen off, and a screen that never
        // turns off never locks on its own.
        let g = AwakeShape.guards(letScreenLock: true, alsoSystemSleep: false)
        Check.that(!g.contains(.display), "no display guard, so the screen may darken and lock")
        Check.that(g.contains(.system), "but the Mac itself is still held up")
        Check.equal(g.assertionTypes, [kIOPMAssertionTypePreventUserIdleSystemSleep],
                    "which is one assertion, the one `caffeinate -i` holds")
    }

    Check.suite("guards: the system guard stops being optional") {
        // With the display guard gone it is the only leg left, so the answer
        // must not depend on the other checkbox. The menu shows it as on and
        // disabled for the same reason.
        Check.equal(AwakeShape.guards(letScreenLock: true, alsoSystemSleep: false),
                    AwakeShape.guards(letScreenLock: true, alsoSystemSleep: true),
                    "same guards either way")
    }

    // Captured with `pmset -g` while Taurine held the display awake.
    let live = """
    System-wide power settings:
    Currently in use:
     standby              1
     Sleep On Power Button 1
     hibernatefile        /var/vm/sleepimage
     powernap             1
     networkoversleep     0
     disksleep            10
     sleep                1 (sleep prevented by caffeinate, caffeinate, powerd)
     hibernatemode        3
     ttyskeepawake        1
     displaysleep         10 (display sleep prevented by taurine)
     tcpkeepalive         1
     powermode            0
     womp                 1
    """

    Check.suite("policy: the live settings are read, not guessed") {
        let p = LockPolicy.parse(live)
        Check.equal(p.displaySleepMinutes, 10, "ten minutes, despite the note after the number")
        Check.that(p.sleepsOnPowerButton, "and this Mac's power button asks for sleep")
        Check.that(p.summary.contains("10 minutes"), "the tooltip says when")
    }

    Check.suite("policy: a display that never sleeps never locks") {
        // 0 is how pmset spells "never", and it is the one setting that makes
        // this whole mode do nothing at all. Saying so is the point.
        let p = LockPolicy.parse(live.replacingOccurrences(of: "displaysleep         10",
                                                           with: "displaysleep         0"))
        Check.isNil(p.displaySleepMinutes, "never")
        Check.that(p.summary.contains("never"), "and the tooltip admits it")
        Check.that(Check.unwrap(p.warning, "a warning is raised")?
                        .contains("Turn display off when inactive") ?? false,
                   "pointing at the setting that fixes it")
    }

    Check.suite("policy: the power button warning outranks nothing else") {
        // Two things can be wrong at once. The display setting is the one that
        // makes the mode useless, so it is the one that gets said first.
        let both = live.replacingOccurrences(of: "displaysleep         10",
                                             with: "displaysleep         0")
        Check.that(LockPolicy.parse(both).warning?.contains("Turn display off") ?? false,
                   "never-sleeping display is reported first")

        let quiet = live.replacingOccurrences(of: "Sleep On Power Button 1",
                                              with: "Sleep On Power Button 0")
        let p = LockPolicy.parse(quiet)
        Check.that(!p.sleepsOnPowerButton, "power button no longer sleeps")
        Check.isNil(p.warning, "and with a working display timeout there is nothing to warn about")
    }

    Check.suite("policy: a settings block it cannot read says nothing it cannot back up") {
        let p = LockPolicy.parse("")
        Check.isNil(p.displaySleepMinutes, "no reading means no claim about the timeout")
        Check.that(!p.sleepsOnPowerButton, "and no claim about the button either")
    }
}
