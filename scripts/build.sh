#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${EVEIL2_BUILD_DIR:-/private/tmp/eveil2-build}"
swift build -c release --scratch-path "$BUILD"
BIN=$(swift build -c release --scratch-path "$BUILD" --show-bin-path)
APP="$PWD/dist/Eveil.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons" "$APP/Contents/Resources"
cp "$BIN/Eveil2" "$BIN/Eveil2Daemon" "$APP/Contents/MacOS/"
swift scripts/make-icon.swift "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/fr.eveil2.daemon.plist "$APP/Contents/Library/LaunchDaemons/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
IDENTITY="${EVEIL2_SIGN_IDENTITY:-7F1822C7592C07CE7485668ADC7C9BB6DD62B1E5}"
codesign --force --sign "$IDENTITY" --options runtime --timestamp --identifier fr.eveil2.daemon "$APP/Contents/MacOS/Eveil2Daemon"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
printf '%s\n' "$APP"
