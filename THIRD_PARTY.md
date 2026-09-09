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

Findings from the provenance gate (run from oss-kit as part of `oss release`,
see the README), and anything else the code learned from somewhere else,
belong here with the date and the reasoning, so the next reader does not
repeat the investigation. What follows is the author's own assessment and not
legal advice.

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

### The `pmset -g` fixture, and the `caffeinate + prevented` finding (2026-08-19, closed 2026-09-09)

`Tests/ScreenLockTests.swift` embeds real `pmset -g` output so `LockPolicy.parse`
is tested against what the tool prints rather than a tidied-up idea of it. The
gate probed `caffeinate + prevented` out of that fixture and found the line in 28
repositories, two of them AGPL-3.0. Convergence, and not even on code: every
project that reads power assertions quotes the same output, because there is only
one thing `pmset` prints, and the text originates with Apple.

Closed rather than kept, because the finding cannot recur. It existed only
because the gate's test-path exclusion was lowercase-only, so `Tests/` read as
product code; Swift capitalises it. That is fixed in oss-kit, and a fixture is
not probed at all now. The principle it stood for, that quoting a system tool's
output is not copying, is worth one sentence and does not need the investigation
behind it.
