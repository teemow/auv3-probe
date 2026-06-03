# Building & installing on Linux with xtool (no Mac)

This guide builds, signs, and installs `auv3-probe` onto an iPad/iPhone
**directly from Linux**, using [xtool](https://github.com/xtool-org/xtool) and a
**free Apple ID**. No Mac, no Xcode, no paid Developer Program.

It exists because newer iOS releases can outrun the Macs you have on hand: an
Xcode old enough to run on an older Mac may be unable to deploy to a current iOS
device (developer-disk-image / version mismatch), and the latest Xcode may not
run on older hardware at all. xtool sidesteps Xcode entirely.

> The canonical project is still the XcodeGen one (`project.yml`, built on macOS
> — see the [README](../README.md)). The xtool path below lives **in this repo**:
> a root `Package.swift` + `xtool.yml` that point straight at the real `Sources/`,
> so both builds share **one** copy of the sources — nothing to keep in sync.

---

## 1. Prerequisites

- **usbmuxd + libimobiledevice** (USB device communication). Install from your
  distro's packages and make sure `usbmuxd` is running.
- **xtool**: download the latest `xtool.AppImage` from the
  [releases](https://github.com/xtool-org/xtool/releases/latest), rename it to
  `xtool`, mark it executable, and put it on your `PATH`.
- **A Swift toolchain** from <https://swift.org/install/linux> — but the version
  matters, see the next section.
- **An `Xcode_<version>.xip`** to extract the iOS SDK from. xtool ships no Apple
  SDKs; you provide the `.xip` yourself and agree to Apple's licence. Any recent
  Xcode works.

## 2. The toolchain ⇄ SDK version rule (read this first)

> **Your Swift toolchain's major.minor version must match the Swift version
> baked into the Xcode SDK you extract.**

The Darwin SDK contains precompiled `.swiftinterface` files for SwiftUI and the
rest of the system frameworks. The Swift compiler refuses to load an interface
that was produced by a different compiler version, failing with:

```
error: failed to build module 'SwiftUI'; this SDK is not supported by the
compiler (the SDK is built with 'Apple Swift version 6.2 ...', while this
compiler is 'Swift version 6.3 ...'). Please select a toolchain which matches
the SDK.
```

Pick the toolchain to match the Xcode you have:

| Xcode you extract | Swift in that SDK | Install this toolchain |
|---|---|---|
| Xcode 16.3        | Swift 6.1         | `swift-6.1-RELEASE`    |
| Xcode 26.x        | Swift 6.2         | `swift-6.2-RELEASE`    |

When in doubt, build once; the error message quotes both versions. Then install
the matching release from swift.org and re-point your environment at it.

## 3. Linux toolchain setup

On a glibc distro that swift.org targets (Ubuntu, etc.) just install the
matching toolchain and you're done.

**On Arch (or any distro with newer library sonames)** the swift.org toolchain
needs a few older sonames that Arch no longer ships. Provide them via a private
`compat-libs` dir on `LD_LIBRARY_PATH` rather than touching the system:

- `libncurses.so.6` — symlink to Arch's `libncursesw.so.6`
- `libxml2.so.2` — extracted from a matching Ubuntu `.deb`
- `libicu*.so.74` (ICU 74) — extracted from a matching Ubuntu `.deb`

Wrap it all in an `env.sh` you source before every swift/xtool command:

```bash
# ~/swift-toolchain/env.sh
export SWIFT_HOME="$HOME/swift-toolchain/swift-6.2-RELEASE-ubuntu24.04/usr"
export PATH="$SWIFT_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/swift-toolchain/compat-libs:$SWIFT_HOME/lib:$LD_LIBRARY_PATH"
```

```bash
source ~/swift-toolchain/env.sh
swift --version    # must report the version that matches your SDK
```

## 4. Install the Darwin SDK

```bash
source ~/swift-toolchain/env.sh
xtool sdk install ~/path/to/Xcode_<version>.xip   # one-time, multi-GB extract
swift sdk list                                    # -> darwin
```

## 5. The in-repo xtool layout (already committed)

xtool builds a SwiftPM package (one library product = the app). The four files
it needs **already live in the repo root** and reuse the existing `Sources/` and
`Resources/` — there is nothing to copy and no second source tree to keep in
sync:

| File | Role |
|------|------|
| `Package.swift` | SwiftPM manifest; its target `path: "Sources"` points at the real sources. `swiftLanguageModes: [.v5]` keeps the Swift-5 semantics (Swift 6 strict concurrency flags the `AVAudioUnit.instantiate` continuation bridge as a data race). |
| `xtool.yml` | xtool config: bundle ID, `infoPath`, `entitlementsPath`, `iconPath`. |
| `xtool-Info.plist` | A dedicated `Info.plist` for xtool — the canonical `Resources/Info.plist` uses XcodeGen `$(...)` substitutions that xtool does not resolve. Carries the local-network keys (`NSLocalNetworkUsageDescription` + ATS `NSAllowsLocalNetworking`) since the app POSTs over the LAN. |

`xtool.yml` reuses the existing entitlements and the asset-catalog icon directly
(xtool does **not** run `actool`, so it can't read `Assets.xcassets` as a
catalog, but it can point straight at the 1024×1024 PNG inside it):

```yaml
version: 1
bundleID: com.teemow.auv3probe
infoPath: xtool-Info.plist
entitlementsPath: Resources/AUv3Probe.entitlements   # inter-app-audio (auv3-discovery.md)
iconPath: Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
```

The `inter-app-audio` entitlement in `Resources/AUv3Probe.entitlements` is
**required so third-party AUv3 plugins show up** (see
[auv3-discovery.md](auv3-discovery.md)). xtool's build output (`xtool/`,
`.build/`) is gitignored.

## 6. Sign in with your Apple ID (interactive, one-time)

```bash
source ~/swift-toolchain/env.sh
xtool auth login     # choose "Password" for a free Apple ID; enter email + 2FA
xtool auth status
```

Notes for free accounts:
- xtool prefixes your bundle ID when signing (e.g. `XTL-XXXX.com.teemow.auv3probe`)
  so it won't collide with anyone else's.
- Signing certificates expire after **7 days**; re-run `xtool dev run` to refresh.

## 7. Build and install to the device

From the **repo root**, the Makefile is the entry point (it sources the toolchain
`env.sh` for you — override with `make deploy SWIFT_ENV=/path/to/env.sh`):

```bash
make devices       # confirm the iPad appears (usbmuxd)
make xtool-build   # optional: cross-compile only, surfaces source errors
make deploy        # build -> sign -> install -> launch over USB
```

`make help` lists every target. Under the hood these run `xtool devices`,
`xtool dev build`, and `xtool dev run --usb` after sourcing `$(SWIFT_ENV)`
(default `~/swift-toolchain/env.sh`) — run them by hand if you prefer.

**Free-account certificate limit.** Free Apple IDs allow only a small number of
development certificates. If one already exists, `xtool dev run` will pause and
ask to **revoke** it before issuing a fresh one:

```
The following certificates must be revoked:
- Apple Development: <your name> (expires ...)
```

Confirm to continue. (Revoking a free-tier *development* cert only affects other
apps you sideloaded with it — those already expire in 7 days anyway.) Run this
in a **real interactive terminal**: if stdin isn't a TTY, xtool safely cancels
instead of guessing.

## 8. Trust the app on the device

First launch is blocked until you trust the developer:

1. **Settings → General → VPN & Device Management** → under *Developer App* tap
   your developer identity → **Trust**.
2. If there's no *Developer App* section, enable **Settings → Privacy &
   Security → Developer Mode** first (the device reboots), then retry.

## 9. Talk to the receiver

The app POSTs each dump to the `cmd/auv3-probe` LAN receiver in the main repo
(`:7800` by default; `GET /healthz`, `POST /auv3-probe`).

- Put the iPad on the **same Wi-Fi** as the receiver host and allow the
  **Local Network** permission prompt on first connect.
- In the app, enter the receiver as `host:7800` and tap **Test connection**.
- **Host firewall:** if the receiver machine runs a default-deny firewall, the
  iPad's connection is dropped before it arrives (the receiver log stays empty).
  Allow the receiver port from your LAN. Example with nftables, scoped to
  private ranges:

  ```bash
  sudo nft insert rule inet filter input tcp dport 7800 \
      ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } accept
  ```

  Reload your on-disk config to drop the rule again when done.

## Troubleshooting quick reference

| Symptom | Cause | Fix |
|---|---|---|
| `SwiftUI ... this SDK is not supported by the compiler` | toolchain ≠ SDK Swift version | install the matching `swift-x.y-RELEASE` (§2) |
| missing `.so` (ncurses / libxml2 / ICU) at runtime | distro ships newer sonames | add the lib to `compat-libs` (§3) |
| `sending '...' risks causing data races` | Swift 6 strict concurrency on Swift-5 code | `swiftLanguageModes: [.v5]` in `Package.swift` |
| `xtool dev run` seems to hang forever | waiting on the interactive revoke prompt | run in a real TTY and answer it (§7) |
| only Apple `AU*` units listed, no third-party | missing Inter-App Audio entitlement | add `inter-app-audio` (§5, [auv3-discovery.md](auv3-discovery.md)) |
| "could not connect to the server" | host firewall dropping the port | allow the receiver port from the LAN (§9) |
