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

# Sign with a stable self-signed identity if present (so the macOS Local Network
# permission persists across rebuilds). Falls back to ad-hoc otherwise.
IDENTITY="PhilipsTVMenubar Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
    echo "Signed with stable identity ($IDENTITY) — Local Network permission persists."
else
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
    echo "Ad-hoc signed. Tip: run ./make-signing-cert.sh once so the Local Network"
    echo "permission survives rebuilds, then rebuild."
fi

echo "Built $APP"
echo "Run it:  open \"$APP\""
