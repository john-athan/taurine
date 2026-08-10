# 1. Tests without a package manager

Date: 2026-08-10
Status: accepted

## Context

Taurine builds with one command and one tool: `swiftc`, over the files in
`Sources/`. Homebrew builds it from source on the user's machine, which is why
there is no notarization step and no Gatekeeper prompt. Nothing is fetched at
build time.

Adding tests the usual way means adding SwiftPM: a `Package.swift`, a
`Tests/TaurineTests` target, a `.build` directory, and a resolution step that
wants the network. That is a real cost paid by everyone who builds the app,
including people who never run a test, and it puts a second, subtly different
build path next to the one that ships.

## Decision

Tests are a second `swiftc` invocation, not a second build system.

`Tests/run.sh` compiles every file in `Sources/` except `Sources/App/main.swift`
together with `Tests/*.swift` into one binary and runs it. `Check` in
`Tests/Harness.swift` is the whole framework: a counter, a list of failures, and
an exit code.

The entry point is generated, not maintained. The script finds every
`func run<Something>Tests()` in `Tests/` and writes a `main.swift` that calls
them in alphabetical order. Adding a test file therefore touches exactly one
file: the new one.

`Sources/App/main.swift` is excluded because Swift only allows top-level code in
a file with that name, and the generated entry point needs the slot. That
constraint is why the CLI moved into `Sources/App/CLI.swift` and `main.swift`
shrank to the six lines that launch it: everything worth testing is now
linkable.

## Consequences

- `make test` works on a clean checkout with no network and no dependencies.
- Tests call production types directly. There is no protocol written purely to
  admit a mock, and no second copy of any logic.
- The harness has no test discovery inside a file, no setup/teardown, no
  parameterisation, and no parallelism. When a suite needs those, it is a sign
  the code under test wants splitting, not that the harness wants growing.
- Anything that reads real hardware is tested twice: once as a pure function
  over captured input, and once as a sanity check against this machine (core
  counts add up, byte counters only ever move forward). The pure half is the
  half that catches regressions on chips we do not own.
