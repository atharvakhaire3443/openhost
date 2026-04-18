#!/bin/bash
# Build OpenHost.app bundle — required for microphone (TCC) permission.
# Usage: ./scripts/make-app.sh [--debug]
set -e

cd "$(dirname "$0")/.."

CONFIG="release"
if [[ "$1" == "--debug" ]]; then CONFIG="debug"; fi

echo "Building OpenHost ($CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/OpenHost"
APP="OpenHost.app"

if [[ ! -f "$BIN" ]]; then
    echo "✗ Binary not found at $BIN"
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenHost"
cp "scripts/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/OpenHost"

# Self-sign with a stable identifier. TCC pins permission grants to the
# designated signing identifier; rebuilding with the SAME identifier preserves
# the grant across rebuilds.
codesign --force --deep --sign - --identifier com.openhost.app "$APP" 2>/dev/null || true

echo "✓ Built $APP"
echo
echo "Run it:  open $APP"
echo
echo "First time you click Record in Transcribe (or the mic in Chat),"
echo "macOS will prompt for microphone access. Approve it."
