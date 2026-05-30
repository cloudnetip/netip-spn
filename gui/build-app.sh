#!/usr/bin/env bash
# Build CloudnetipSPN.app from the Swift package.
#
# Usage:
#   ./build-app.sh [VERSION] [OUTPUT_DIR]
#
# Env vars:
#   UNIVERSAL=1  build a fat arm64+x86_64 binary (default for releases)
#   UNIVERSAL=0  build only for the host architecture (faster, dev mode)

set -euo pipefail

VERSION="${1:-dev}"
OUT="${2:-./build}"
UNIVERSAL="${UNIVERSAL:-1}"
APP="$OUT/Cloudnetip SPN.app"

cd "$(dirname "$0")"

if [ "$UNIVERSAL" = "1" ]; then
    echo "==> swift build (release, universal arm64+x86_64)"
    swift build -c release --arch arm64 --arch x86_64
    BIN=".build/apple/Products/Release/CloudnetipSPN"
else
    echo "==> swift build (release, native arch)"
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/CloudnetipSPN"
fi
[ -f "$BIN" ] || { echo "build failed: $BIN missing"; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/CloudnetipSPN"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> done: $APP"
echo "    architectures: $(lipo -archs "$APP/Contents/MacOS/CloudnetipSPN")"
