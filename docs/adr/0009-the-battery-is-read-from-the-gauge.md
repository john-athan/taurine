# 9. The battery is read from the gauge, and the wall figure has to corroborate itself

Date: 2026-08-15
Status: accepted

## Context

The activity panel answered "what is this Mac spending?" in watts of silicon and
said nothing at all about the plug. On a laptop that is half the question: a
MacBook charging at 21 W while its package draws half a watt is doing something
the power tile cannot see, because the energy counters behind that tile describe
the chip and nothing else.

Taurine already talks to the SMC, for the charge limiter, so reading charge and
current from SMC keys would have cost nothing but a key table. ADR 3 settled
what a key table is worth: those keys are undocumented, they move between chip
generations, and when one is wrong it is not blank, it is a confident number.
The same argument that keeps temperatures out of this panel keeps the battery
off the SMC.

The gauge itself is not a secret. `AppleSmartBattery` in the IO registry
publishes what it knows to any process that asks: state of charge, whether an
adapter is attached, whether the cell is taking anything, the pack current in
milliamps and the pack voltage in millivolts, the attached adapter's rating, and
the firmware's own estimate of time to full or empty. `System Information` and
`coconutBattery` read the same properties. No root, no entitlement, no
undocumented key names beyond the property names `ioreg` prints.

One number people want is not in that list: what is actually coming out of the
wall. It exists, in a `PowerTelemetryData` dictionary that is documented nowhere
at all.

## Decision

The battery tile reads `AppleSmartBattery` registry properties, and the wall
figure is required to prove itself before it is shown.

- Charge is the ratio of `CurrentCapacity` to `MaxCapacity`, not either one read
  as a percentage: Apple Silicon counts percent against 100, Intel Macs count
  milliamp hours against the pack, and the ratio is the answer in both.
- Flow is `Amperage` times `Voltage`, and its **sign is the direction**. Every
  numeric field is read as a sixty-four bit pattern reinterpreted as signed,
  because some of them arrive as the unsigned spelling of a negative and a
  discharging Mac must not appear to charge at eighteen quintillion watts.
- `PowerTelemetryData` supplies the adapter draw, and is checked twice before it
  is believed: it has to satisfy its own identity (what comes in is what the
  machine uses plus what the battery takes) and its battery figure has to agree
  with the current and voltage the gauge publishes separately. Either check
  failing means the tile shows the adapter's rating alone.
- A Mac with no battery is not a Mac with a broken battery. The probe asks the
  power sources whether an internal battery exists at all; a desktop opens the
  probe cleanly, writes nothing, and gets a panel one tile shorter with no
  complaint in the footer. The probe fails loudly only when a battery is
  reported and the gauge then refuses to describe it.
- An adapter's rating is drawn in whole watts and a measured flow keeps its
  decimal. The rating is printed on a label; the flow is a measurement, and the
  two should not look like the same kind of number.

## Consequences

- The panel answers "is it charging, and how fast" without a password, an
  entitlement, or a private framework. It is a registry property fetch once a
  second, only while the panel is open.
- The undocumented part of this is confined to one number and one function. If
  `PowerTelemetryData` changes shape or disappears, the corroboration fails and
  the tile falls back to the adapter's rating, which is the behaviour a Mac that
  never published it already gets.
- The tile's height is the same plugged in and unplugged, so pulling the cable
  out while the panel is open does not resize it. Everything conditional lives
  on rows that are drawn either way.
- Battery health, cycle count and cell voltages are all sitting in the same
  dictionary and are all deliberately left out. This panel says what the machine
  is doing now; how worn the cell is after two hundred cycles is a different
  question, asked at a different cadence, by somebody who is not glancing at a
  menu bar popover.
