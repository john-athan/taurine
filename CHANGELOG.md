# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); `oss release` reads the
`## [version]` sections.

## [Unreleased]

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
