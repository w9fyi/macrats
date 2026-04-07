#!/bin/bash
# scripts/make-app-bundle.sh — wrap the SwiftPM `macrats` executable in a
# proper macOS .app bundle with an Info.plist and ad-hoc code signature.
#
# MacRats is built primarily with SwiftPM (`swift build`, `swift test`)
# because that keeps the protocol + session + model layers testable
# headlessly on any machine. But SwiftPM can't produce a real `.app`
# bundle with metadata on its own, so for "I want to drop MacRats.app
# in /Applications and double-click it" workflows we run this script.
#
# The script is idempotent — running it twice produces the same bundle.
# It's also fast (~1s) because it just copies the already-built binary
# from .build/ into a Contents/MacOS/ layout and drops an Info.plist
# next to it.
#
# Usage:
#     scripts/make-app-bundle.sh                       # debug build, ad-hoc signed
#     scripts/make-app-bundle.sh release               # release build, ad-hoc signed
#     scripts/make-app-bundle.sh release universal    # release universal (arm64 + x86_64)
#     scripts/make-app-bundle.sh release open          # release + open on completion
#
# Output:
#     build/MacRats.app (a real macOS bundle you can drag to /Applications)

set -euo pipefail

# Script sits in scripts/, project root is one up.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# ---- Parse args ---------------------------------------------------------

CONFIGURATION="debug"
DO_OPEN="no"
UNIVERSAL="no"
for arg in "$@"; do
    case "$arg" in
        debug)     CONFIGURATION="debug" ;;
        release)   CONFIGURATION="release" ;;
        open)      DO_OPEN="yes" ;;
        universal) UNIVERSAL="yes" ;;
        -h|--help)
            echo "Usage: $0 [debug|release] [universal] [open]"
            exit 0
            ;;
        *)
            echo "Unknown arg: $arg" >&2
            exit 1
            ;;
    esac
done

# ---- Version info -------------------------------------------------------

# Use the git short hash as the build number and tag-or-hash as version.
BUILD_NUMBER="$(git rev-parse --short HEAD 2>/dev/null || echo "dev")"
if VERSION_TAG="$(git describe --tags --exact-match 2>/dev/null)"; then
    VERSION="${VERSION_TAG#v}"
else
    # No tag on this commit — fall back to 0.1.0-<hash>
    VERSION="0.1.0-${BUILD_NUMBER}"
fi

echo "==> MacRats.app bundle ($CONFIGURATION)"
echo "    version: $VERSION"
echo "    build:   $BUILD_NUMBER"
echo ""

# ---- Build the SwiftPM executable --------------------------------------

echo "==> Building SwiftPM target 'macrats' ($CONFIGURATION, universal=$UNIVERSAL)..."
if [ "$UNIVERSAL" = "yes" ]; then
    if [ "$CONFIGURATION" != "release" ]; then
        echo "ERROR: universal builds require release configuration" >&2
        exit 1
    fi
    # SwiftPM 6.x supports passing --arch twice to produce a fat binary
    # under .build/apple/Products/Release/.
    swift build --configuration release --product macrats \
        --arch arm64 --arch x86_64
    BIN_PATH=".build/apple/Products/Release/macrats"
elif [ "$CONFIGURATION" = "release" ]; then
    swift build --configuration release --product macrats
    BIN_PATH=".build/release/macrats"
else
    swift build --product macrats
    BIN_PATH=".build/debug/macrats"
fi

if [ ! -f "$BIN_PATH" ]; then
    echo "ERROR: expected binary not found at $BIN_PATH" >&2
    exit 1
fi

# ---- Assemble the .app layout ------------------------------------------

APP_DIR="build/MacRats.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Assembling $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

# Copy the executable. Rename if necessary so CFBundleExecutable matches.
cp "$BIN_PATH" "$MACOS/macrats"
chmod +x "$MACOS/macrats"

# Generate the Info.plist from the template, substituting version info.
# sed is fine here — the placeholders are unique.
sed \
    -e "s/__VERSION__/$VERSION/g" \
    -e "s/__BUILD__/$BUILD_NUMBER/g" \
    "$SCRIPT_DIR/macrats-Info.plist" \
    > "$CONTENTS/Info.plist"

# PkgInfo: the 8-byte file macOS uses as a fast file-type hint. Always
# "APPL????" for a normal .app bundle.
printf 'APPL????' > "$CONTENTS/PkgInfo"

# ---- Ad-hoc code signature ---------------------------------------------
#
# Ad-hoc signing (-) is enough for running locally. Real distribution
# requires a Developer ID certificate + notarization, which is a v1.0
# release task, not a dev-loop task.

echo "==> Ad-hoc signing..."
codesign --force --sign - --timestamp=none "$APP_DIR"

# Verify the signature — fails loudly if something's off.
codesign --verify --verbose=2 "$APP_DIR"

# ---- Done --------------------------------------------------------------

echo ""
echo "==> Bundle ready: $APP_DIR"
echo "    Size: $(du -sh "$APP_DIR" | cut -f1)"
echo "    To run: open $APP_DIR"
echo "    To install: cp -r $APP_DIR /Applications/"

if [ "$DO_OPEN" = "yes" ]; then
    echo ""
    echo "==> Opening..."
    open "$APP_DIR"
fi
