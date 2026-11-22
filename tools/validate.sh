#!/bin/sh
# Every check this project has, in one script.
#
# Run it directly, through `oss check`, or let CI call it. Tests run on
# fixtures and pure functions, so nothing here needs a permission grant or
# a network.
set -eu
cd "$(dirname "$0")/.."

printf '\n== build\n'
tools/build-app.sh

printf '\n== test\n'
tools/test.sh

printf '\nvalidate: everything passes\n'
