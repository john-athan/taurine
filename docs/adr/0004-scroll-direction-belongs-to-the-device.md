# 4. Scroll direction belongs to the device, not to the Mac

Date: 2026-08-10
Status: accepted

## Context

macOS has one scroll direction setting for the whole machine:
`com.apple.swipescrolldirection`. Turn it on and everything scrolls naturally,
which is right for a trackpad and for the Magic Mouse, where the content follows
your fingers. Turn it off and everything scrolls the traditional way, which is
right for a wheel mouse, where the wheel pushes the page.

Anyone who uses both a laptop trackpad and a wheel mouse has to pick which of
the two feels wrong. This is the first entry in a category of settings Taurine
is willing to carry: things the system should have got right, where the fix is
small, local, and reversible.

## Decision

Taurine watches scroll events, works out what kind of device produced each one,
and flips the ones the system got backwards.

The classification is the shape of the event itself, not a device database.
Trackpads and the Magic Mouse emit continuous, pixel-precise scroll events with
phase and momentum. A wheel mouse emits discrete, line-based ticks. Any one of
continuity, a non-zero phase or a non-zero momentum phase is taken as a surface.
That needs no list of vendor IDs and it stays right about hardware released
after this code was written.

It is also, as written, the most permissive rule of its family, and that is a
known weakness rather than an oversight. See "What this gets wrong" below.

The rule is stated in terms of the system setting rather than replacing it:

- Trackpads and Magic Mouse should scroll naturally.
- Wheel mice should scroll traditionally.
- Whichever class disagrees with the current global setting gets its deltas
  negated. The other class is passed through untouched.

Turn the system setting off and the correction simply moves to the other class,
so the feature works the same for people who prefer the traditional feel on
their trackpad. The global default is observed for changes, so flipping it in
System Settings takes effect without a restart.

Momentum and phase-continuation events are continuous by definition and follow
the trackpad rule, which keeps inertial scrolling coherent.

## What this gets wrong

An event's shape is a property of whatever driver last touched it, not of the
thing under your hand. Two other projects have hit this in production:

- **UnnaturalScrollWheels** classified exactly the way Taurine does, on the
  continuity flag alone. Its issue #4 reports, reproduced by the maintainer in a
  VM, that "Logitech Options modifies scroll events to be 'continuous' which
  will cause UnnaturalScrollWheels to believe the event came from a trackpad".
  The answer was a second, opt-in detection method, merged as PR #5 in August
  2020. The first method was not repaired, because it cannot be.
- **Mos** classifies on phase, momentum phase and scroll count, and then carries
  a special case that looks up the process id of the Logitech daemon and forces
  the answer back to "mouse" for events that came from it. Committed in February
  2021 under the message "feat: saving the MX Master".

Both projects fixed this by taking a term *out* of the heuristic or by escaping
it entirely. Neither found a shape-based rule that works. Taurine's rule is the
union of three signals, so it is the easiest of all of them to fool: a mouse
needs to trip only one of the three to be mistaken for a trackpad.

So, concretely: **with Logi Options+ or similar vendor software driving your
mouse, this feature will appear to do nothing to that mouse.** The menu will say
it is on and correcting, and your mouse will keep scrolling the way the system
setting says. Nothing is broken and nothing needs re-granting. The workarounds,
in the order most people will want them, are to invert the wheel in the vendor
software itself, which owns the events by then; or to quit the vendor software
and let Apple's own driver present the mouse.

**The better design, and why it is not here yet.** LinearMouse does not look at
event shape at all. It reads the originating device from the event and asks the
HID system what that device is: `CGEventCopyIOHIDEvent`, then the event's sender
id, then `IOHIDEventSystemClientCopyServiceForRegistryID`, then
`IOHIDServiceClientConformsTo(client, kHIDPage_Digitizer, kHIDUsage_Dig_TouchPad)`.
That asks about the hardware, so no driver can lie to it by reshaping an event.
Mac Mouse Fix takes the sender id more cheaply still, straight out of
`CGEvent` field 87.

That is where this should go. It was attempted here and abandoned on evidence,
measured on this Mac on macOS 26:

- The sender id round trip mostly works: of 250 `IOHIDEventService` nodes in the
  IO registry, 243 resolved to a service client by registry id.
- It does not work for the device that matters. The built-in trackpad's node,
  `AppleMultitouchTrackpadHIDEventDriver`, resolves to nil, and not one of the
  243 that did resolve conforms to `Digitizer`/`TouchPad`. The trackpad *is*
  visible as a conforming service when the service list is enumerated directly,
  so the service exists; it is the lookup by registry id that fails to reach it.
- Shipping it anyway would mean a primary path that silently fails to the rule
  we already have, on the one machine available to test it, written against
  private symbol signatures that could not be checked against a working call.

This Mac has only a built-in trackpad, so the mouse half of any classifier is
untestable here either way. That is the honest state: the device-based rule is
the right answer, it is not written, and the reason is recorded above rather
than left to be rediscovered.

**Left open deliberately**: whether Apple's own driver sets continuity or phase
for a plain or high-resolution wheel mouse with no vendor software present. It
was not measured and nothing here depends on assuming it either way. Nothing is
claimed about SteerMouse or USB Overdrive.

## Consequences

- This needs an event tap that modifies events, and macOS grants that only with
  Accessibility permission. It is the first permission prompt Taurine has ever
  shown, so the feature is off by default, explains itself before asking, and
  says plainly when the permission is missing rather than silently doing
  nothing.
- Accessibility permission is granted to a specific build of a specific binary.
  Taurine is ad-hoc signed and built from source, so rebuilding or upgrading
  produces a binary the system does not recognise and the permission has to be
  granted again. The app detects that state and says so, instead of appearing
  broken.
- The tap modifies events, so it is a `.defaultTap` and every scroll on the
  machine waits on it. What it does not do is poll: it costs nothing when
  nothing is scrolling and it adds no timer, so the badge still reads `0 timers`
  with the feature on. Calling it passive would be wrong in the way that
  matters, because a modifying tap is one that can stall the whole machine.
- Because it can stall the machine, the tap gets a thread of its own and the
  callback is kept to one branch, six field reads and six field writes, with
  no allocation and no lock. macOS disables a tap that takes too long to answer,
  and the app re-arms it if that ever happens.
- Taking the tap down is synchronous: `stop()` does not return until the tap
  thread has left its run loop. Anything less means the callback can still be
  running over memory the app has released.
- Only scroll wheel events are tapped by this feature. Taurine sees no
  keystrokes and no mouse buttons on account of it. (ADR 6 later added a
  keyboard tap for a different fix. It is a separate tap, switched on
  separately, and it exists only while Finder is the front application.)
- A mouse driven by vendor software may not be corrected at all, and the menu
  cannot tell that this has happened. See "What this gets wrong".
- The premise that a session tap sees deltas *after* macOS has applied
  `com.apple.swipescrolldirection` is not proven here. Synthetic events posted at
  the HID point come through a session tap unchanged under either setting, so
  that experiment cannot answer it, and the question was not worth changing a
  user's setting for longer than the moment it took to try. The corroboration is
  circumstantial but strong: UnnaturalScrollWheels, Mos and LinearMouse all
  negate at a session tap, all coexist with the system setting, and natural is
  the setting a Mac ships with. If the tap saw pre-transform deltas, all three
  would be inverted for most of their users. Thirty seconds with a wheel mouse
  settles it for good, and if it ever comes out the other way, the correction is
  inverted and this ADR is wrong with it.
