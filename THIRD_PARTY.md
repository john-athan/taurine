# Third-party material in Taurine

Taurine is MIT licensed. This file records anything in the repository that
originated elsewhere, so an attribution obligation cannot hide in the gap
between "we wrote it" and "nobody checked".

## Dependencies

None. `Package.swift` declares no external packages. The app builds against
Apple's SDK frameworks only (AppKit, IOKit, ServiceManagement and friends),
which are used under the Apple Developer Program agreement and are not
redistributed by this repository.

## Bundled assets

`assets/taurine.gif` is a screen recording of the app, made for this repository.

The menu bar glyphs are SF Symbols, drawn from the system at runtime. SF Symbols
are licensed by Apple for use in software running on Apple platforms and may not
be redistributed as artwork. No symbol is exported into this repository.

## Reviewed and cleared

Nothing yet. Findings from `scripts/provenance-check.py` that turn out to be
convergent output rather than copying belong here, with the date and the
reasoning, so the next reader does not repeat the investigation.
