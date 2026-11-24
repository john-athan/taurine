#!/bin/bash
# Install a built app: copy it, sign it with this Mac's own certificate, and
# clear the permissions macOS still holds for a copy it no longer recognises.
#
#   tools/install-app.sh <App.app> [folder, default /Applications]
#
# `make install` runs it, and so does the Homebrew formula's <name>-install.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ $# -ge 1 ] && [ -d "$1" ] || { echo "usage: $0 <App.app> [folder]" >&2; exit 2; }
SRC=$1
DIR=${2:-/Applications}
DEST="$DIR/$(basename "$SRC")"
ID=$(plutil -extract CFBundleIdentifier raw -o - "$SRC/Contents/Info.plist")

requirement() { codesign -d -r- "$1" 2>/dev/null | sed -nE 's/^(# )?designated => //p'; }
BEFORE=$(requirement "$DEST" || true)

# Signed next to its place and then moved there, so a failed signature leaves
# the installed copy as it was.
mkdir -p "$DIR"
STAGE=$(mktemp -d "$DIR/.install.XXXXXX")
trap 'rm -rf "${STAGE:?}"' EXIT
cp -R "$SRC" "$STAGE/"
NEW="$STAGE/$(basename "$SRC")"
chmod -R u+w "$NEW"
"$HERE/sign-app.sh" --create "$NEW"
codesign --verify --strict "$NEW"

RUNNING=no
if pkill -f "^$DEST/Contents/MacOS/" 2>/dev/null; then
  RUNNING=yes
  for _ in $(seq 50); do pgrep -f "^$DEST/Contents/MacOS/" >/dev/null || break; sleep 0.1; done
fi
if [ -e "$DEST" ]; then mv "$DEST" "$STAGE/old"; fi
mv "$NEW" "$DEST" || { [ ! -e "$STAGE/old" ] || mv "$STAGE/old" "$DEST"; exit 1; }
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
echo "▸ installed $DEST"

# Only when the identity changed: those grants cannot match any more, and the
# dead entry keeps macOS from asking again.
if [ -n "$BEFORE" ] && [ "$BEFORE" != "$(requirement "$DEST")" ]; then
  tccutil reset All "$ID" >/dev/null 2>&1 || true
  echo "▸ new signature: macOS asks for its permissions once more, and keeps them from then on"
fi
if [ "$RUNNING" = yes ]; then open "$DEST"; fi
