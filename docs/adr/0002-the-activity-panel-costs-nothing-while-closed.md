# 2. The activity panel costs nothing while it is closed

Date: 2026-08-10
Status: accepted

## Context

Taurine's menu badge reads `45.2 MB · 0 timers · 0 sockets`, live from the
kernel. That badge is the product: every other keep-awake app claims to be
lightweight, and this one lets you check.

An activity panel is the first feature that genuinely needs a repeating timer.
Every system monitor on the Mac solves this by sampling all the time and keeping
history, which is how a menu bar utility ends up costing a percent of a core
forever so that a window nobody has open can be up to date.

## Decision

Nothing samples until the panel is visible, and nothing survives it closing.

- `ActivityMonitor.start(interval:)` opens the probes and creates the one
  repeating timer in the app. `stop()` cancels it, closes every probe and drops
  them. There is no paused state and no warm cache.
- `ActivityProbe` makes that lifecycle explicit: `open()` acquires mach ports,
  IOKit services and IOReport subscriptions; `close()` gives them all back.
- History for the sparklines lives in the panel's view, so it dies with the
  panel. A closed panel remembers nothing, which is also the honest behaviour:
  a graph of the last minute is a lie if the app was not watching for that
  minute.
- The panel prints its own cost, in the same form as the menu badge. The menu
  badge cannot do this job: the popover is transient, so opening the menu
  dismisses the panel, and a badge that always reads `0 timers` proves nothing
  about the panel. Inside the panel the number is both live and checkable,
  which is the point.
- The panel is built the first time somebody opens it, and the teardown paths
  ask whether it exists rather than asking for it. Quitting a Taurine whose
  panel was never opened must not construct a popover in order to close it.

The panel is an `NSPopover` hung off the status item, opened from a menu item,
drawn by hand into an `NSView`.

- A popover, not a window: the system owns placement, the arrow, the shadow, and
  dismissal on click-away, and it tells us exactly when it closed, which is the
  hook the whole lifecycle hangs on.
- A popover, not a view inside the menu: menu tracking runs its own run loop
  mode, swallows most interaction, and closes on the first click. A panel with a
  live graph does not belong inside a menu.
- Drawn by hand, not SwiftUI. Linking SwiftUI pulls its framework into the
  process at launch, for a window that is usually never opened, and the resident
  figure on the badge would go up for everybody. AppKit and Core Graphics are
  already loaded.

## Consequences

- Sampling runs on a utility queue, not the main thread, and samples arrive on
  the main queue complete. Reading IOReport takes single-digit milliseconds.
- Probes take their baseline readings in `open()`, and the first sample follows
  a quarter of a second later. A panel whose first frame is blank looks broken,
  and one that waits a full second before saying anything feels slow; opening
  the probes is the moment the clock starts, so neither happens. Every sample
  carries a positive interval and no probe has to describe a state it has no
  baseline for.
- Opening the panel is slightly more expensive than keeping it warm would be:
  probes open, counters take a baseline reading. That is the trade, and it is
  paid by the person who asked to see it.
