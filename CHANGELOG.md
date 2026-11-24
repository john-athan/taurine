# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); `oss release` reads the
`## [version]` sections.

## [Unreleased]

### Changed
- The Accessibility grant survives upgrades: installing signs the app with a certificate made on your Mac, and clears the dead entry of an older build so macOS asks one last time
- Homebrew: `taurine-install` copies and signs the app, instead of `cp -R`, and the `taurine` command runs the installed copy

## [1.7.4] - 2026-11-22

### Changed
- taurine -- <command> exits 128+n when the command dies from a signal, as a shell would, instead of the bare signal number that scripts read as an ordinary failure code
- The app icon is the bull from the terminal, (o@) in glowing red dot matrix on a CRT tile, and the social card follows it
- Add a social card and put the app icon above the README title
- Build, test and install through oss-kit's shared Swift Makefile and test harness; Taurine's own steps move to app.mk, TapThreads to its own test file
- Build and test through the shared Swift scripts, add a changelog
- Fleet base from oss-kit: dependabot generated from the repo's kinds, runtime versions in pin files that CI reads, and what else the fleet now requires here (licence, check script, Info.plist as version source)

## [1.7.3] - 2026-11-22

### Fixed
- CFBundleVersion matches the release version again

## [1.7.2] - 2026-11-16

### Changed
- New app icon: a bull, wide awake

## [1.7.1] - 2026-10-28

### Fixed
- The activity panel has an opaque floor and legible labels on macOS 27

## [1.7.0] - 2026-09-27

### Changed
- Shows no watts instead of 0 W when macOS 27 freezes the energy counters

### Removed
- The charge limiter, which macOS 27 now owns

## [1.6.2] - 2026-09-21

### Fixed
- Closed a pending finding about the pmset test fixture

## [1.6.1] - 2026-09-09

### Fixed
- The charge daemon's plist is staged where nothing else can reach it
- A flaky live battery check in the tests, and tests that cannot be answered in a virtual machine now say so

### Added
- CI on macOS

## [1.6.0] - 2026-08-19

### Added
- The screen can lock while the Mac keeps working

## [1.5.0] - 2026-08-15

### Added
- Says whether the Mac is charging, and how fast
- Third-party provenance is recorded in THIRD_PARTY.md

## [1.4.0] - 2026-08-10

### Added
- Finder gets its other two keys, and shift-cmd-V has one meaning

## [1.3.1] - 2026-08-10

### Fixed
- A cut is no longer spent on a paste that uses it

## [1.3.0] - 2026-08-10

### Added
- Cmd-X and cmd-V cut and paste files in Finder, sharing one event tap with the other fixes

## [1.2.0] - 2026-08-10

### Added
- Activity panel with a per-device scroll fix
- Interface counters that are not truncated, and energy readings that fail loudly instead of quietly

### Changed
- Sources are grouped by subsystem, with a test harness

## [1.1.0] - 2026-08-04

### Added
- Charge limiting
- Opt-in guard to keep the Mac awake with the lid closed

## [1.0] - 2026-07-10

- First release: keeps your Mac awake, with a reason
