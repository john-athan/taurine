# 10. Awake with the screen locked is the same session minus one assertion

Date: 2026-08-19
Status: accepted

## Context

Taurine's job was described as "keep the Mac awake", and the shape of that in
the code was two assertions: `PreventUserIdleDisplaySleep` always, and
`PreventUserIdleSystemSleep` when the owner asked for it. That is the shape
every caffeine app has, and it quietly bundles two things that are not the same
thing.

The request that broke the bundle: leave long jobs running (builds, uploads,
coding agents that work for an hour without a keystroke) and walk away from an
unlocked laptop. Today those are mutually exclusive. Holding the display
assertion means macOS never turns the screen off, so it never starts a screen
saver, so the idle lock configured in System Settings never fires. Nothing is
wrong with the lock. The lock is simply never reached.

Nothing else was in the way. A locked screen does not suspend, throttle, or
signal anything: the login window is a window, the session behind it keeps its
processes, its file handles and its network connections. `caffeinate -i` has
held exactly this shape for as long as it has existed.

The parts that genuinely cannot be delivered are worth writing down, because
they are the ones people discover at the wrong moment:

- An idle assertion refuses *idle* sleep. It has no opinion about a sleep
  somebody asked for. Apple menu > Sleep, a closed lid, and on Macs where
  `Sleep On Power Button` is 1, the power button, all take a path that no
  assertion sees. ADR 0009's neighbour, `ClamshellGuard`, exists because the lid
  needed `pmset disablesleep` and admin rights for the same reason.
- An automatic lock has to be idle-aware or it fires while you are typing. The
  only idle clock that costs nothing is the one the window server already runs,
  and the moment Taurine ships its own it also ships a timer, an input tap and a
  badge that has to stop saying `0 timers`.
- With the screen dark, anything that needs the display to exist stops working:
  screenshots, GUI automation, and any agent driving a visible window. Terminal
  work does not care.

## Decision

Letting the screen lock is a preference that subtracts the display assertion,
and the automatic lock is macOS's own.

- `AwakeShape.guards(letScreenLock:alsoSystemSleep:)` is the whole rule, as
  arithmetic over two stored answers rather than a branch in the menu bar app,
  because `taurine -- <command>` holds its own assertions and has to reach the
  same conclusion from the same preference.
- When the mode is on the session holds `PreventUserIdleSystemSleep` and nothing
  else. The system checkbox stops being a choice there and the menu shows it on
  and disabled, because it has become the only leg the Mac is standing on.
- The automatic lock is the owner's existing display sleep timeout plus their
  existing Lock Screen setting. Taurine adds no timer, no tap, and no polling,
  and the diagnostics badge still reads `0 timers` while the mode is on.
- The manual lock is `SACLockScreenImmediate` from the private `login`
  framework, fetched with `dlsym` the way ADR 0003 fetches IOReport, with
  `pmset displaysleepnow` as the fallback if a future macOS drops the symbol. It
  locks without asking anything to sleep, which is the property that matters:
  ⌃⌘Q does the same and is worth preferring over the power button.
- `LockPolicy` reads the two settings that decide whether any of this behaves as
  expected, `displaysleep` and `Sleep On Power Button`, out of `pmset -g` when
  the menu opens, and the tooltip says what it found. A display set to never
  sleep will never lock, and a power button set to sleep will end the very
  processes the mode exists to protect. Both are said out loud rather than left
  to be discovered.

## Consequences

The mode is off by default. An install that upgrades into a suddenly locking
screen would be a bug wearing a feature's clothes.

Taurine now spawns `pmset -g` when the menu opens, and only while the mode is
on. That is a process per menu open, paid by the owner who asked for the mode,
and never while idle.

The lock is honest about what it cannot do, and the tooltip is where the
qualification lives. The power button in particular is not something Taurine can
intercept or repair; the only lever is `pmset -a powerbutton 0`, which is
system-wide, persistent and admin-gated, and one flag of that kind in the
codebase (the lid guard) is already one to be careful with. Taurine reports the
setting and points at ⌃⌘Q instead.

`SACLockScreenImmediate` is private. It resolves on macOS 26.5.2 and has for
many releases, but the fallback exists because that is a statement about today.
