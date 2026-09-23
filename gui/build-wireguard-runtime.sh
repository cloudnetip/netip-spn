#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/wireguard-runtime.conf"
OUT="${1:-$ROOT/gui/.build/wireguard-runtime}"
UNIVERSAL="${UNIVERSAL:-1}"
CACHE="${WIREGUARD_CACHE_DIR:-$ROOT/gui/.build/wireguard-cache}"

[ -f "$MANIFEST" ] || { echo "missing $MANIFEST" >&2; exit 1; }
# shellcheck disable=SC1090
source "$MANIFEST"

EXPECTED_RUNTIME="wg-${WIREGUARD_TOOLS_VERSION}+wireguard-go-${WIREGUARD_GO_VERSION}+r${RUNTIME_REVISION}"
if [ "${FORCE_WIREGUARD_RUNTIME:-0}" != "1" ] && \
   [ -x "$OUT/wg" ] && [ -x "$OUT/wireguard-go" ] && [ -f "$OUT/runtime.version" ] && \
   [ -f "$OUT/wireguard-tools-COPYING" ] && [ -f "$OUT/wireguard-go-LICENSE" ] && \
   [ -f "$OUT/Sources/wireguard-tools-${WIREGUARD_TOOLS_VERSION}.tar.xz" ] && \
   [ "$(tr -d '\r\n' < "$OUT/runtime.version")" = "$EXPECTED_RUNTIME" ]; then
    echo "==> bundled WireGuard runtime cached: $EXPECTED_RUNTIME"
    exit 0
fi

WG_TOOLS_URL="https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-${WIREGUARD_TOOLS_VERSION}.tar.xz"
WG_GO_URL="https://git.zx2c4.com/wireguard-go/snapshot/wireguard-go-${WIREGUARD_GO_VERSION}.tar.xz"
TOOLS_ARCHIVE="$CACHE/wireguard-tools-${WIREGUARD_TOOLS_VERSION}.tar.xz"
GO_ARCHIVE="$CACHE/wireguard-go-${WIREGUARD_GO_VERSION}.tar.xz"
SRC="$CACHE/src"
TOOLS_SRC="$SRC/wireguard-tools-${WIREGUARD_TOOLS_VERSION}"
GO_SRC="$SRC/wireguard-go-${WIREGUARD_GO_VERSION}"
BUILD="$CACHE/build"

mkdir -p "$CACHE" "$SRC" "$BUILD"

fetch_checked() {
    local url="$1" file="$2" expected="$3"
    if [ ! -f "$file" ] || [ "$(shasum -a 256 "$file" | awk '{print $1}')" != "$expected" ]; then
        rm -f "$file"
        echo "==> downloading $(basename "$file")"
        curl -fL --retry 3 --retry-delay 2 "$url" -o "$file"
    fi
    local actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || {
        echo "sha256 mismatch for $file" >&2
        echo "expected: $expected" >&2
        echo "actual:   $actual" >&2
        exit 1
    }
}

fetch_checked "$WG_TOOLS_URL" "$TOOLS_ARCHIVE" "$WIREGUARD_TOOLS_SHA256"
fetch_checked "$WG_GO_URL" "$GO_ARCHIVE" "$WIREGUARD_GO_SHA256"

rm -rf "$TOOLS_SRC" "$GO_SRC"
tar -xJf "$TOOLS_ARCHIVE" -C "$SRC"
tar -xJf "$GO_ARCHIVE" -C "$SRC"

build_arch() {
    local arch="$1" goarch cc sdkroot
    case "$arch" in
        arm64) goarch=arm64 ;;
        x86_64) goarch=amd64 ;;
        *) echo "unsupported macOS architecture: $arch" >&2; exit 1 ;;
    esac

    local arch_out="$BUILD/$arch"
    rm -rf "$arch_out"
    mkdir -p "$arch_out"

    echo "==> wireguard-go ${WIREGUARD_GO_VERSION} ($arch)"
    (
        cd "$GO_SRC"
        CGO_ENABLED=0 GOOS=darwin GOARCH="$goarch" go build -trimpath -ldflags="-s -w" -o "$arch_out/wireguard-go" .
    )

    echo "==> wg ${WIREGUARD_TOOLS_VERSION} ($arch)"
    cc="$(xcrun --sdk macosx --find clang)"
    sdkroot="$(xcrun --sdk macosx --show-sdk-path)"
    [ -x "$cc" ] || { echo "macOS clang not found via xcrun" >&2; exit 1; }
    [ -d "$sdkroot" ] || { echo "macOS SDK not found via xcrun: $sdkroot" >&2; exit 1; }

    make -C "$TOOLS_SRC/src" clean >/dev/null
    SDKROOT="$sdkroot" \
    MACOSX_DEPLOYMENT_TARGET=13.0 \
    CFLAGS="-O3 -arch $arch -isysroot $sdkroot -mmacosx-version-min=13.0" \
    LDFLAGS="-arch $arch -isysroot $sdkroot -mmacosx-version-min=13.0" \
    make -C "$TOOLS_SRC/src" wg \
        PLATFORM=darwin \
        CC="$cc" \
        WIREGUARD_TOOLS_VERSION="$WIREGUARD_TOOLS_VERSION" >/dev/null
    cp "$TOOLS_SRC/src/wg" "$arch_out/wg"
}

if [ "$UNIVERSAL" = "1" ]; then
    build_arch arm64
    build_arch x86_64
    rm -rf "$OUT"
    mkdir -p "$OUT"
    lipo -create "$BUILD/arm64/wg" "$BUILD/x86_64/wg" -output "$OUT/wg"
    lipo -create "$BUILD/arm64/wireguard-go" "$BUILD/x86_64/wireguard-go" -output "$OUT/wireguard-go"
else
    case "$(uname -m)" in
        arm64) arch=arm64 ;;
        x86_64) arch=x86_64 ;;
        *) echo "unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
    esac
    build_arch "$arch"
    rm -rf "$OUT"
    mkdir -p "$OUT"
    cp "$BUILD/$arch/wg" "$OUT/wg"
    cp "$BUILD/$arch/wireguard-go" "$OUT/wireguard-go"
fi

chmod 0755 "$OUT/wg" "$OUT/wireguard-go"
printf 'wg-%s+wireguard-go-%s+r%s\n' \
    "$WIREGUARD_TOOLS_VERSION" "$WIREGUARD_GO_VERSION" "$RUNTIME_REVISION" > "$OUT/runtime.version"
cp "$TOOLS_SRC/COPYING" "$OUT/wireguard-tools-COPYING"
cp "$GO_SRC/LICENSE" "$OUT/wireguard-go-LICENSE"
mkdir -p "$OUT/Sources"
cp "$TOOLS_ARCHIVE" "$OUT/Sources/"

printf '==> bundled WireGuard runtime: '
cat "$OUT/runtime.version"
