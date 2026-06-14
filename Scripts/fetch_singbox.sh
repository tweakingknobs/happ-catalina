#!/bin/bash
# Downloads the Catalina-safe sing-box used for system-wide TUN mode and assembles
# the universal binary the app bundles. Pinned to v1.9.0 — its x86_64 slice is
# minos 10.13 (go1.22, runs on Catalina). v1.9.5+ moved to go1.23 -> minos 11.0.
set -euo pipefail

VERSION="1.9.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/VPN/Resources/singbox"
BASE="https://github.com/SagerNet/sing-box/releases/download/v$VERSION"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> downloading sing-box $VERSION (amd64 + arm64)"
curl -fL "$BASE/sing-box-$VERSION-darwin-amd64.tar.gz" -o "$WORK/amd.tgz"
curl -fL "$BASE/sing-box-$VERSION-darwin-arm64.tar.gz" -o "$WORK/arm.tgz"
tar xzf "$WORK/amd.tgz" -C "$WORK"
tar xzf "$WORK/arm.tgz" -C "$WORK"
AMD="$(find "$WORK" -name sing-box -path '*amd64*' | head -1)"
ARM="$(find "$WORK" -name sing-box -path '*arm64*' | head -1)"

echo "==> verifying x86_64 slice runs on Catalina"
MINOS="$(vtool -show-build "$AMD" 2>/dev/null | awk '/minos/{print $2}')"
echo "    amd64 minos = $MINOS"
case "$MINOS" in 10.*) : ;; *) echo "ERROR: minos=$MINOS not Catalina-safe" >&2; exit 1 ;; esac

echo "==> lipo universal + sign"
mkdir -p "$DEST"
lipo -create "$AMD" "$ARM" -output "$DEST/sing-box"
chmod +x "$DEST/sing-box"
codesign --force --sign - "$DEST/sing-box"
lipo -info "$DEST/sing-box"
echo "    -> $DEST/sing-box"
