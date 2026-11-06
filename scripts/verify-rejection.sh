#!/bin/bash
set -euo pipefail
APP="${1:-/Applications/Eveil2.app}"
TEST_DIR=$(mktemp -d /private/tmp/eveil2-untrusted.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
cp "$APP/Contents/MacOS/Eveil2" "$TEST_DIR/Eveil2Untrusted"
# Preserve the claimed identifier, but deliberately remove the Developer ID chain.
codesign --force --sign - --identifier fr.eveil2.app "$TEST_DIR/Eveil2Untrusted"
if "$TEST_DIR/Eveil2Untrusted" --probe > "$TEST_DIR/reply" 2> "$TEST_DIR/error"; then
    echo 'FAIL: forged identifier was accepted'; exit 1
fi
# A negative result only proves authentication when the genuine client still works.
"$APP/Contents/MacOS/Eveil2" --probe > /dev/null
printf 'PASS: ad-hoc client with genuine identifier rejected; genuine client succeeds\n'
