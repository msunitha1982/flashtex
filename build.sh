#!/bin/bash
#
# build.sh — build FlashTeX (Swift/AppKit) and assemble FlashTeX.app
#
# Usage: ./build.sh            # release build + .app bundle
#        ./build.sh --debug    # debug build + .app bundle

set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then
    CONFIG="debug"
fi

echo "==> Building FlashTeX ($CONFIG)..."
swift build -c "$CONFIG"

BIN_PATH=".build/$CONFIG/FlashTeX"
APP="FlashTeX.app"

echo "==> Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN_PATH" "$APP/Contents/MacOS/FlashTeX"
cp Info.plist "$APP/Contents/Info.plist"

# Bundle the Catppuccin palette so the Appearance settings can load it.
PALETTE="/Users/arya/Downloads/Actually Useful Stuff/Random Stuff/palette.json"
if [[ -f "$PALETTE" ]]; then
    cp "$PALETTE" "$APP/Contents/Resources/palette.json"
else
    echo "    (warn) palette.json not found at $PALETTE — using built-in fallback"
fi

# Ad-hoc sign so macOS is happy launching it locally (no dev certificate needed).
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> Done: $APP"
echo "    Launch with: open \"$APP\""
