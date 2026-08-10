# 3. Power readings come from IOReport, not from powermetrics

Date: 2026-08-10
Status: accepted

## Context

The numbers people actually want from a Mac system monitor are the ones Apple
does not publish: watts drawn by the CPU, the GPU and the Neural Engine, and the
frequency each cluster is running at. Public API has none of them.

The usual answer is `powermetrics`, which is what `mactop` and `asitop` shell
out to. It works, and it costs a root password: `powermetrics` refuses to run
without one. For an app whose entire pitch is that it asks for nothing, shipping
a feature that opens with an admin prompt is the wrong trade. Taurine asks for
admin in two places already, to install the charge daemon and to hold the lid
open, and both of them buy something that genuinely cannot be had otherwise. A
readout is not that.

`powermetrics` itself is a thin client over `IOReport`, a private but stable
framework in the dyld cache. IOReport's energy counters are readable by an
ordinary user process. Verified on this machine: `dlopen` of
`/usr/lib/libIOReport.dylib` succeeds and every symbol we need resolves, with no
elevation and no entitlement.

## Decision

Power and frequency come from IOReport, reached by `dlopen` and `dlsym`.

- Symbols are looked up at runtime, never linked against. A missing symbol on
  some future macOS disables the power tile and leaves the rest of the panel
  working.
- Energy counters are cumulative. Two samples are subtracted and divided by the
  elapsed time, and the unit label on the channel (`mJ`, `uJ`, `nJ`) decides the
  scale factor. No unit is assumed.
- Frequencies come from state residency counters, not from an instantaneous
  reading: the reported figure is the residency-weighted average over the
  sampling interval, which is what the hardware actually did.
- Everything IOReport provides is optional in the sample. An Intel Mac, a locked
  down future OS, or a channel that disappears produces a panel without a power
  tile, not a panel of zeros.

The App Store is not a constraint: Taurine ships through Homebrew, built from
source on the user's machine.

## Consequences

- No password, ever, for the activity panel, and nothing it does could ask for
  one later: reading is all it can do.
- A private interface can change. The blast radius is bounded by the previous
  point, and the parsing is covered by tests over captured channel data, so a
  change shows up as a failing test rather than as a wrong number.
- The public probes (processor ticks, memory statistics, block storage counters,
  interface counters, GPU utilisation) stay on public API. IOReport is used for
  what only IOReport can answer, and nothing else.
- Temperatures are deliberately absent. The SMC keys that carry them are
  undocumented and move between chip generations; `ProcessInfo.thermalState` is
  public, honest, and enough to say when the machine is under thermal pressure.
