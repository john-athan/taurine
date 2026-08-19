# Third-party material in Taurine

Taurine is MIT licensed. This file records anything in the repository that
originated elsewhere, so an attribution obligation cannot hide in the gap
between "we wrote it" and "nobody checked".

## Dependencies

None, and there is no manifest that could acquire one. `build.sh` gathers every
`.swift` file under `Sources/` and hands the list to `swiftc`; there is no
`Package.swift`, no Xcode project and no package manager. The app links Apple's
SDK frameworks only (Cocoa, IOKit, Carbon, ServiceManagement), which are used
under the Apple Developer Program agreement and are not redistributed by this
repository.

## Bundled assets

`assets/taurine.gif` is a screen recording of the app, made for this repository.

The menu bar glyphs are SF Symbols, drawn from the system at runtime. SF Symbols
are licensed by Apple for use in software running on Apple platforms and may not
be redistributed as artwork. No symbol is exported into this repository.

## Reviewed and cleared

Findings from `scripts/provenance-check.py`, and anything else the code learned
from somewhere else, belong here with the date and the reasoning, so the next
reader does not repeat the investigation. What follows is the author's own
assessment and not legal advice.

### The SMC charge keys, and the `CH0C` finding (2026-08-14)

`Sources/Charge/ChargeLimit.swift` credits a contributor to
[AlDente](https://github.com/davidwernhart/AlDente) for the fact that `CH0B`
alone is not enough on pre-26 Apple silicon: without `CH0C` set as well,
charging can quietly resume during sleep. That is a fact about how an
undocumented Apple interface behaves, discovered by someone else and recorded
here with the credit attached. No AlDente code was read into this repository,
and the two implementations do not resemble each other: AlDente drives a bundled
`smc` executable, `Sources/Charge/SMC.swift` holds one `IOServiceOpen` for the
life of the process.

The same applies to the 80-byte `SMCKeyData_t` layout that file encodes. It is
the shape AppleSMC expects, published in Apple's own kext sources and reproduced
in every SMC tool since, several of them GPL. The offsets are the interface; the
code that assembles them here was written by hand, byte by byte, precisely so it
did not have to be taken from anywhere.

### The `pmset -g` fixture, and the `caffeinate + prevented` finding (2026-08-19)

`Tests/ScreenLockTests.swift` embeds a block of `pmset -g` output, captured on
this Mac, so that `LockPolicy.parse` is tested against the real thing rather
than against a tidied-up idea of it. One of those lines,

    sleep                1 (sleep prevented by caffeinate, caffeinate, powerd)

is printed by `pmset`, which ships with macOS. The provenance check probes the
two rarest identifiers on a line, here `caffeinate` and `prevented`, and found
that line in 28 other repositories, two of them AGPL-3.0:
[Acerola-1/hagimi-monitor](https://github.com/Acerola-1/hagimi-monitor) and
[voidengineer-911/whisky-claude](https://github.com/voidengineer-911/whisky-claude).

The verdict is convergence, not copying. Every project that reads power
assertions pastes the same tool output into the same kind of fixture, because
there is only one thing `pmset` prints. No code from either repository was read
into this one, and neither was consulted while writing `Sources/Awake/ScreenLock.swift`.
Copyright does not attach here to Taurine's use of a system tool's output, and
in any case the text originates with Apple's `pmset`, not with the repositories
the search returned.

The wider list of matches on that same probe is the same finding: a couple of
dozen menu bar caffeine apps whose tests quote `pmset`.
