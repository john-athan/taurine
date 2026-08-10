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

The classification is the event's own continuity flag, not a device database.
Trackpads and the Magic Mouse emit continuous, pixel-precise scroll events with
phase and momentum. A wheel mouse emits discrete, line-based ticks. That
distinction is exactly the one that matters here, it needs no list of vendor
IDs, and it is right about hardware released after this code was written.

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
- The tap is passive: it costs nothing when nothing is scrolling, and it adds no
  timer. The badge still reads `0 timers` with the feature on.
- macOS disables a tap that takes too long to answer. The callback does one
  branch and a few field writes, and the app re-arms the tap if the system ever
  disables it.
- Only scroll wheel events are tapped. Taurine sees no keystrokes and no mouse
  buttons.
