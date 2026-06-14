#!/bin/bash
# Builds VPN.app (universal, Catalina-targeted, ad-hoc-signed) plus the privileged
# helper, without Xcode project files.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/VPN.app"
DEPLOY="10.15"

FW=(-framework AppKit -framework Foundation -framework Security
    -framework SystemConfiguration -framework CFNetwork)

# App sources = everything EXCEPT the helper's own main.swift (which has its own entry
# point). The shared VPNHelperProtocol.swift IS included in the app.
APP_SRC=$(find "$ROOT/VPN" -name '*.swift' ! -path '*/Helper/main.swift' | sort)
# Helper sources = its main + the shared protocol.
HELPER_SRC="$ROOT/VPN/Helper/main.swift $ROOT/VPN/Helper/VPNHelperProtocol.swift"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

build_universal() { # $1=out  $2..=sources
  local out="$1"; shift
  swiftc -O -target "x86_64-apple-macosx${DEPLOY}" "${FW[@]}" "$@" -o "${out}-x86_64"
  swiftc -O -target "arm64-apple-macosx${DEPLOY}"  "${FW[@]}" "$@" -o "${out}-arm64"
  lipo -create "${out}-x86_64" "${out}-arm64" -output "$out"
  rm -rf "${out}-x86_64" "${out}-arm64" "${out}-x86_64.dSYM" "${out}-arm64.dSYM"
  strip -x "$out" 2>/dev/null || true
  chmod +x "$out"
}

echo "==> compiling app (universal, min macOS $DEPLOY)"
build_universal "$APP/Contents/MacOS/VPN" $APP_SRC

echo "==> compiling privileged helper (universal)"
build_universal "$BUILD/vpnhelper" $HELPER_SRC

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

echo "==> ad-hoc codesign (inner binaries first, then app)"
for b in Resources/xray/xray Resources/singbox/sing-box Resources/helper/vpnhelper MacOS/VPN; do
  codesign --force --sign - "$APP/Contents/$b"
done
codesign --force --sign - "$APP"

echo "==> strip quarantine"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "==> verify"
lipo -info "$APP/Contents/MacOS/VPN"
lipo -info "$APP/Contents/Resources/singbox/sing-box"
lipo -info "$APP/Contents/Resources/helper/vpnhelper"
for slice in xray/xray singbox/sing-box; do
  echo -n "$slice amd64 minos: "; vtool -show-build -arch x86_64 "$APP/Contents/Resources/$slice" 2>/dev/null | grep minos | tr -s ' '
done
echo -n "VPN amd64 minos: "; vtool -show-build -arch x86_64 "$APP/Contents/MacOS/VPN" 2>/dev/null | grep minos | tr -s ' '
codesign -dv "$APP" 2>&1 | grep -iE "signature|identifier" | head -2 || true
echo "==> done: $APP"
