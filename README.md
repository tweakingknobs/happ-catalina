# VPN

A native macOS menu-bar VPN/proxy client (like Happ / v2box / v2RayTun) that runs on
**macOS 10.15 Catalina and later**. It consumes a proxy **subscription** URL, runs
[Xray-core](https://github.com/XTLS/Xray-core) locally, and routes the Mac's traffic
through it by setting the system proxy.

Bring your own subscription URL — paste it on first launch (no key ships with the app).

## Two modes

- **Proxy only** (default): runs Xray locally and points the macOS system proxy at it. No
  background components; covers browsers + proxy-aware apps. After the first connect it may
  ask for your admin password once to change the proxy.
- **System-wide (TUN)**: tunnels **every** app via a real `utun` interface (like a normal
  VPN). This needs a small **privileged helper**, installed **once** with a single admin
  prompt. After that it runs as a background root service and **no `sudo`/password is needed
  per launch**. Switch modes in the menu under **Mode**.

## How it works

- **Proxy engine:** bundles Xray-core **v1.8.23** (the newest build whose Intel slice still
  runs on Catalina — `minos 10.13`). Newer Xray is built with Go ≥1.23 and requires macOS 11.
- **TUN engine:** bundles **sing-box v1.9.0** (`minos 10.13`). Its `tun` inbound creates the
  utun, takes over the default route (`auto_route`), and binds its own upstream connections
  to the physical interface (`auto_detect_interface`) so the VPN's traffic to the servers
  doesn't loop back through the tunnel. A `urltest` group auto-selects the fastest live node.
- **Privileged helper:** a root `LaunchDaemon` (`ru.local.vpn.helper`) that the app talks to
  over XPC. Its only job is to run the bundled sing-box with a config the app sends. Installed
  once via an admin-authorized script (`/Library/Application Support/VPN/`, plist in
  `/Library/LaunchDaemons/`). Remove it any time from the menu (**Remove system VPN helper**).
- **Safety:** before declaring "Connected", the app verifies real egress through the tunnel;
  if it can't reach the internet it tears the tunnel down and restores routing, so a dead
  tunnel can't strand the Mac. sing-box restores the route table on shutdown; a health monitor
  drops the "Connected" state if the tunnel dies.
- **Subscription:** fetches the URL with a `v2RayTun/2.0` User-Agent and a stable `x-hwid`
  device header (required to unlock real nodes on Remnawave/Happ-style services). Parses the
  returned Xray-JSON config array (one entry per region) — or a base64 `vless://…` URI list.
- **Connect:** transforms the chosen region into a runnable config (drops the `xhttp`
  transport that v1.8.23 can't run, keeps gRPC / REALITY+Vision; simplifies routing to
  "private → direct, everything → fastest live node"), launches Xray exposing a local
  SOCKS5 (`127.0.0.1:10808`) + HTTP (`10809`) proxy, verifies real egress through it, then
  points the macOS system proxy at it.
- **Disconnect / quit / crash:** restores the previous system-proxy settings. A snapshot is
  written to disk before connecting and swept on the next launch if the app crashed.

## Build

Prerequisites: macOS with Xcode command-line tools (Swift 5.5+). The bundled Xray binary is
already committed under `VPN/Resources/xray/`; to re-fetch it:

```sh
./Scripts/fetch_xray.sh     # downloads + verifies + lipos Xray v1.8.23 (universal)
./Scripts/fetch_singbox.sh  # downloads + verifies + lipos sing-box v1.9.0 (universal, for TUN)
```

Build the universal, ad-hoc-signed `.app`:

```sh
./Scripts/build.sh          # -> build/VPN.app
```

This compiles for `x86_64` and `arm64` at deployment target 10.15, assembles the bundle,
ad-hoc signs it, and strips quarantine.

## Run (on a Catalina Mac)

1. Copy `build/VPN.app` to `/Applications`.
2. First launch: **right-click → Open → Open** (it's unsigned/ad-hoc, so Gatekeeper asks once).
3. A shield icon appears in the menu bar. Open the menu → **Change subscription…** and paste
   your subscription URL.
4. Click the icon → **Connect**. The first connect asks for your admin password once (to
   change the system proxy). Pick a different country under **Region**.

If Gatekeeper still blocks the embedded core, run once:
`xattr -dr com.apple.quarantine /Applications/VPN.app`

## Menu

- **Connect / Disconnect**
- **Region** — switch country/profile (reconnects through the new region)
- **Update subscription** / **Change subscription…** — paste any subscription URL
- **Reset device ID** — generate a new `x-hwid` (needs a free device slot on the provider)
- usage / expiry line from the subscription metadata

## Project layout

```
VPN/
  App/           AppDelegate, main, Info.plist
  Core/          XrayBinary, XrayRunner, ConfigStore, EgressProbe, PortFinder, Errors
  Subscription/  SubscriptionManager, SubscriptionParser, URIOutboundBuilder, SubMetadata, HWID, XrayProfile
  Proxy/         SystemProxy
  State/         AppModel, ConnectionState
  UI/            StatusItemController, AddSubscriptionWindow, StatusIcon
  Resources/xray/ xray (universal), geoip.dat, geosite.dat
Scripts/         fetch_xray.sh, build.sh
```

## Notes / limitations

- **TUN mode installs a root helper** (one admin prompt, ever). It's an unsigned/ad-hoc build,
  so the helper accepts XPC connections from a process whose executable lives in `VPN.app`
  (a best-effort guard, not a strong security boundary). Remove it any time via the menu.
- **Proxy mode** covers browsers and proxy-aware apps only. Changing the system proxy needs
  admin rights; expect one password prompt per connect unless your setup allows `networksetup`
  without elevation.
- For a **distributable, fully sandboxed** system VPN you'd use a NetworkExtension, which needs
  an Apple Developer account + notarization — intentionally avoided here per the unsigned setup.
- Some providers gate clients to "only HAPP"; this client presents a compatible request
  signature so you can use **your own** subscription for personal use.
