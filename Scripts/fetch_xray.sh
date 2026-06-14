#!/bin/bash
# Downloads the Catalina-safe Xray-core and assembles the universal binary the app
# bundles. Pinned to v1.8.23 — its x86_64 slice is minos 10.13 (runs on Catalina).
# DO NOT bump to v1.8.24+: those are built with Go >=1.23 -> minos 11.0 -> won't
# launch on macOS 10.15.
set -euo pipefail

VERSION="v1.8.23"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/VPN/Resources/xray"
BASE="https://github.com/XTLS/Xray-core/releases/download/$VERSION"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> downloading Xray-core $VERSION (amd64 + arm64)"
curl -fL "$BASE/Xray-macos-64.zip"        -o "$WORK/amd.zip"
curl -fL "$BASE/Xray-macos-arm64-v8a.zip" -o "$WORK/arm.zip"
unzip -oq "$WORK/amd.zip" -d "$WORK/amd"
unzip -oq "$WORK/arm.zip" -d "$WORK/arm"

echo "==> verifying x86_64 slice runs on Catalina (minos must be <= 10.15)"
MINOS="$(vtool -show-build "$WORK/amd/xray" 2>/dev/null | awk '/minos/{print $2}')"
echo "    amd64 minos = $MINOS"
case "$MINOS" in
  10.*) : ;;  # 10.x is fine for Catalina
  *) echo "ERROR: amd64 minos=$MINOS is not Catalina-safe. Use an older Xray." >&2; exit 1 ;;
esac

echo "==> lipo universal + assemble"
mkdir -p "$DEST"
lipo -create "$WORK/amd/xray" "$WORK/arm/xray" -output "$DEST/xray"
chmod +x "$DEST/xray"
cp "$WORK/amd/geoip.dat"   "$DEST/geoip.dat"
cp "$WORK/amd/geosite.dat" "$DEST/geosite.dat"

echo "==> ad-hoc sign"
codesign --force --sign - "$DEST/xray"

echo "==> result"
lipo -info "$DEST/xray"
vtool -show-build -arch x86_64 "$DEST/xray" 2>/dev/null | grep minos
echo "    -> $DEST/{xray,geoip.dat,geosite.dat}"
