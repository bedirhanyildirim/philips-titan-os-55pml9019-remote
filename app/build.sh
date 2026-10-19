#!/bin/bash
# Build PhilipsTVMenubar.app (a locally-signed .app bundle, not notarized).
set -e
cd "$(dirname "$0")"

echo "Building (release)…"
swift build -c release

APP="dist/PhilipsTVMenubar.app"
BIN="$(swift build -c release --show-bin-path)/PhilipsTVMenubar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/PhilipsTVMenubar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# ad-hoc sign so macOS lets it run locally
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
echo "Run it:  open \"$APP\""
