#!/bin/bash
# Sign an app bundle so macOS recognises the next build as the same app.
#
#   tools/sign-app.sh <App.app>            the local identity if there is one, else ad-hoc
#   tools/sign-app.sh --create <App.app>   make the local identity first if there is none
#
# An ad-hoc signature is a hash of the binary, so every rebuild is a new app to
# macOS and its Accessibility grant is dead. A signature with a certificate is
# recognised by that certificate and the bundle id, which a rebuild keeps. The
# certificate is self-signed, made on this Mac, shared by every app built with
# this script, and trusted for nothing. The key is not exportable and sits in
# a keychain of its own, whose password is in the login keychain.
#
# Building never creates it, so CI and Homebrew's sandbox stay ad-hoc.
# Once it exists, failing to use it is an error: falling back to ad-hoc would
# quietly cost the grants again.
set -euo pipefail

CREATE=no
if [ "${1:-}" = "--create" ]; then CREATE=yes; shift; fi
[ $# -eq 1 ] && [ -d "$1" ] || { echo "usage: $0 [--create] <App.app>" >&2; exit 2; }
APP=$1
ID=$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")

SERVICE="local-app-signing"
KEYCHAIN="$HOME/Library/Keychains/$SERVICE.keychain-db"

identity() { security find-identity -p codesigning "$KEYCHAIN" | sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) .*/\1/p' | head -1; }

create() (
  # Passwords go through stdin or a private file, never through an argument list.
  umask 077
  T=$(mktemp -d)
  trap 'rm -rf "${T:?}"' EXIT
  PASS=$(/usr/bin/openssl rand -hex 24)
  printf '%s' "$PASS" > "$T/pass"
  cat > "$T/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Local app signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
  # Twenty years: a new certificate would be a new app to macOS once more.
  /usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 7300 \
    -keyout "$T/key.pem" -out "$T/cert.pem" -config "$T/cert.cnf" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout "file:$T/pass"
  # The password is stored first: a keychain nobody can open is worse than none.
  # security -i reads the commands from stdin.
  security -i >/dev/null <<SEC
add-generic-password -U -a $SERVICE -s $SERVICE -w $PASS
create-keychain -p $PASS "$KEYCHAIN"
unlock-keychain -p $PASS "$KEYCHAIN"
import "$T/id.p12" -k "$KEYCHAIN" -P $PASS -x -T /usr/bin/codesign
set-key-partition-list -S apple-tool:,apple: -s -k $PASS "$KEYCHAIN"
SEC
  [ -n "$(identity)" ]
)

if [ ! -f "$KEYCHAIN" ] && [ "$CREATE" = yes ]; then
  echo "▸ making a signing certificate for the apps built on this Mac…"
  create || { security delete-keychain "$KEYCHAIN" 2>/dev/null || true; echo "could not make the signing certificate in $KEYCHAIN" >&2; exit 1; }
fi

if [ ! -f "$KEYCHAIN" ]; then
  codesign --force --sign - --identifier "$ID" "$APP"
  exit 0
fi

PASS=$(security find-generic-password -a "$SERVICE" -s "$SERVICE" -w) || {
  echo "the password for $KEYCHAIN is not in the login keychain, or that is locked" >&2; exit 1; }
printf 'unlock-keychain -p %s "%s"\n' "$PASS" "$KEYCHAIN" | security -i >/dev/null
trap 'security lock-keychain "$KEYCHAIN" 2>/dev/null || true' EXIT
HASH=$(identity)
[ -n "$HASH" ] || { echo "no signing certificate in $KEYCHAIN" >&2; exit 1; }
codesign --force --sign "$HASH" --keychain "$KEYCHAIN" --timestamp=none --identifier "$ID" "$APP"
