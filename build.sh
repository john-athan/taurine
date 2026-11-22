#!/bin/sh
# Kept for the Homebrew formula, which runs ./build.sh for old tags and new ones.
exec "$(dirname "$0")/tools/build-app.sh" "$@"
