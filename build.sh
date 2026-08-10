#!/bin/bash
# Build Taurine.app from Sources/. No Xcode project, no dependencies — just swiftc.
set -euo pipefail
cd "$(dirname "$0")"

APP="Taurine.app"
BIN="$APP/Contents/MacOS/taurine"

echo "▸ compiling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# Sources/ is grouped by subsystem (App, Awake, Charge, Activity, Scroll), so the
# file list is gathered rather than globbed. Sorted, so a build is reproducible.
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' | sort)
swiftc -O -o "$BIN" "${SOURCES[@]}" \
  -framework Cocoa -framework IOKit -framework Carbon -framework ServiceManagement

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Taurine</string>
  <key>CFBundleDisplayName</key><string>Taurine</string>
  <key>CFBundleIdentifier</key><string>io.github.john-athan.taurine</string>
  <key>CFBundleVersion</key><string>1.3.1</string>
  <key>CFBundleShortVersionString</key><string>1.3.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>taurine</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHumanReadableCopyright</key><string>MIT — no affiliation with any energy drink.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so Login Items / launch work on this machine.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "▸ built $PWD/$APP"
echo "  install:  cp -R $APP /Applications/ && open /Applications/$APP"
echo "  CLI:      sudo ln -sf /Applications/$APP/Contents/MacOS/taurine /usr/local/bin/taurine"
