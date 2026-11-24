#!/bin/bash
# Build build/<App>.app from Sources/ (or main.swift). No Xcode project, no
# SwiftPM, no dependencies, just swiftc. One script for every Swift app here;
# what differs between apps is in Info.plist (name, executable, identifier,
# version) and app.env (frameworks, flags, resources).
set -euo pipefail
cd "$(dirname "$0")/.."

FRAMEWORKS="" SWIFTC_FLAGS="" LINK_FLAGS="" RESOURCES=""
# shellcheck disable=SC1091
. ./app.env

# Info.plist is the only place the name and version are written, and the
# bundle gets it unchanged, so what was linted is what ships.
plutil -lint Info.plist >/dev/null
plist() { plutil -extract "$1" raw -o - Info.plist; }
NAME=$(plist CFBundleName)
EXE=$(plist CFBundleExecutable)

APP="build/$NAME.app"
echo "▸ compiling $NAME $(plist CFBundleShortVersionString)…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

# Sources/ is grouped by subsystem, so the file list is gathered rather than
# globbed. Sorted, so a build is reproducible. A small app is one main.swift.
SOURCES=()
if [ -d Sources ]; then
  while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' | sort)
else
  SOURCES=(main.swift)
fi

LINK=()
for fw in $FRAMEWORKS; do LINK+=(-framework "$fw"); done
# shellcheck disable=SC2086
swiftc -O $SWIFTC_FLAGS -o "$APP/Contents/MacOS/$EXE" "${SOURCES[@]}" ${LINK[@]+"${LINK[@]}"} $LINK_FLAGS

if [ -n "$RESOURCES" ]; then
  mkdir -p "$APP/Contents/Resources"
  # shellcheck disable=SC2086
  cp $RESOURCES "$APP/Contents/Resources/"
fi

# With this Mac's own certificate if it has one, so a rebuild keeps its grants;
# otherwise ad-hoc, which does not.
tools/sign-app.sh "$APP"

echo "▸ built $PWD/$APP"
