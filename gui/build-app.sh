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

echo "==> building bundled WireGuard runtime"
UNIVERSAL="$UNIVERSAL" ./build-wireguard-runtime.sh "$(pwd)/.build/wireguard-runtime"

RUNTIME_OUT="$(pwd)/.build/wireguard-runtime"
ROOT="$(cd .. && pwd)"
if [ "$UNIVERSAL" = "1" ]; then
    echo "==> building privileged helper (universal arm64+x86_64)"
    (cd "$ROOT" && GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "-s -w -X main.version=$VERSION" -o "$RUNTIME_OUT/helper-arm64" .)
    (cd "$ROOT" && GOOS=darwin GOARCH=amd64 go build -trimpath -ldflags "-s -w -X main.version=$VERSION" -o "$RUNTIME_OUT/helper-x86_64" .)
    lipo -create "$RUNTIME_OUT/helper-arm64" "$RUNTIME_OUT/helper-x86_64" -output "$RUNTIME_OUT/helper"
    rm -f "$RUNTIME_OUT/helper-arm64" "$RUNTIME_OUT/helper-x86_64"
else
    case "$(uname -m)" in
        arm64) GOARCH=arm64 ;;
        x86_64) GOARCH=amd64 ;;
        *) echo "unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
    esac
    echo "==> building privileged helper (native)"
    (cd "$ROOT" && GOOS=darwin GOARCH="$GOARCH" go build -trimpath -ldflags "-s -w -X main.version=$VERSION" -o "$RUNTIME_OUT/helper" .)
fi
chmod 0755 "$RUNTIME_OUT/helper"

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

if [ -f "Resources/MenuBarIconTemplate.png" ]; then
    cp "Resources/MenuBarIconTemplate.png" "$APP/Contents/Resources/MenuBarIconTemplate.png"
fi

mkdir -p "$APP/Contents/Resources/WireGuard"
cp -R .build/wireguard-runtime/. "$APP/Contents/Resources/WireGuard/"

echo "==> ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> done: $APP"
echo "    architectures: $(lipo -archs "$APP/Contents/MacOS/CloudnetipSPN")"
