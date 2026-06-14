#!/bin/bash
# Build VPN.app ON a macOS Catalina (Intel) machine. Compiles x86_64 only — Catalina's
# toolchain has no arm64 macOS SDK, so the universal build.sh can't be used there.
# The bundled xray/sing-box are universal and run on Intel via their x86_64 slice.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/VPN.app"
DEPLOY="10.15"
FW=(-framework AppKit -framework Foundation -framework Security
    -framework SystemConfiguration -framework CFNetwork)

APP_SRC=$(find "$ROOT/VPN" -name '*.swift' ! -path '*/Helper/main.swift')
HELPER_SRC="$ROOT/VPN/Helper/main.swift $ROOT/VPN/Helper/VPNHelperProtocol.swift"

echo "==> checking toolchain"
command -v swiftc >/dev/null || { echo "swiftc not found. Run: xcode-select --install"; exit 1; }
for f in "$ROOT/VPN/Resources/xray/xray" "$ROOT/VPN/Resources/singbox/sing-box"; do
  [ -f "$f" ] || { echo "Missing bundled binary: $f"; exit 1; }
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> compiling app (x86_64, min macOS $DEPLOY)"
swiftc -O -target "x86_64-apple-macosx${DEPLOY}" "${FW[@]}" $APP_SRC -o "$APP/Contents/MacOS/VPN"

echo "==> compiling helper (x86_64)"
swiftc -O -target "x86_64-apple-macosx${DEPLOY}" -framework Foundation $HELPER_SRC -o "$BUILD/vpnhelper"

echo "==> bundle resources"
cp "$ROOT/VPN/App/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/VPN/Resources/AppIcon.icns" ] && cp "$ROOT/VPN/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
mkdir -p "$APP/Contents/Resources/xray" "$APP/Contents/Resources/singbox" "$APP/Contents/Resources/helper"
cp "$ROOT/VPN/Resources/xray/xray"        "$APP/Contents/Resources/xray/xray"
cp "$ROOT/VPN/Resources/xray/geoip.dat"   "$APP/Contents/Resources/xray/geoip.dat"
cp "$ROOT/VPN/Resources/xray/geosite.dat" "$APP/Contents/Resources/xray/geosite.dat"
cp "$ROOT/VPN/Resources/singbox/sing-box" "$APP/Contents/Resources/singbox/sing-box"
cp "$BUILD/vpnhelper"                     "$APP/Contents/Resources/helper/vpnhelper"
cp "$ROOT/VPN/Helper/ru.local.vpn.helper.plist" "$APP/Contents/Resources/helper/ru.local.vpn.helper.plist"
chmod +x "$APP/Contents/Resources/xray/xray" "$APP/Contents/Resources/singbox/sing-box" "$APP/Contents/Resources/helper/vpnhelper"

echo "==> ad-hoc codesign"
for b in Resources/xray/xray Resources/singbox/sing-box Resources/helper/vpnhelper MacOS/VPN; do
  codesign --force --sign - "$APP/Contents/$b"
done
codesign --force --sign - "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "==> done: $APP"
lipo -info "$APP/Contents/MacOS/VPN" 2>/dev/null || file "$APP/Contents/MacOS/VPN"
