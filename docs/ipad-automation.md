# Automating the iPad from Linux

Launch AUv3 Probe and AUM, take screenshots, and tap, press, or swipe by
accessibility label or by position, all from Linux over USB, with no Mac. It builds on
[building-on-linux.md](building-on-linux.md), which installs the app with xtool.
[`scripts/ipad`](../scripts/ipad) wraps everything below:

```bash
scripts/ipad tunnel                      # terminal 1, keep running
scripts/ipad launch aum
scripts/ipad screenshot                  # -> ~/.cache/go-ios/screenshots/ipad-<time>.png
scripts/ipad wda                         # terminal 2, keep running (needed for tap, tree, gestures)
scripts/ipad tap "LAST STATE" aum        # AUM loads its last session
```

## What needs what

| You want | Needs |
|---|---|
| launch an app, screenshot, list apps/processes | the go-ios tunnel |
| tap, press, swipe, or read the UI (`tap`, `tap-at`, `hold`, `swipe`, `size`, `tree`) | the tunnel **+** a mounted developer disk image **+** WebDriverAgent installed and running **+** UI Automation enabled, iPad unlocked |

Launching and screenshots work without a disk image. Only UI automation needs the
whole stack.

## One-time setup

### 1. go-ios

Install [go-ios](https://github.com/danielpaulus/go-ios) as `ios` on your
`PATH` (see [building-on-linux.md §1](building-on-linux.md#1-prerequisites)). The
helper also needs `curl`, `python3`, and `openssl`.

`scripts/ipad tunnel` keeps go-ios's pairing identity in `~/.config/go-ios`
(mode 700). The `selfIdentity.plist` there holds a **private key**; never copy it
into a repository.

### 2. Developer disk image (only for tapping)

On iOS 17+, WebDriverAgent's test service (`com.apple.dt.testmanagerd.remote`)
only exists once a **personalized** developer disk image is mounted, and the
image must be recent enough for the device's iOS. Xcode ships it. Without Xcode,
[doronz88/DeveloperDiskImage](https://github.com/doronz88/DeveloperDiskImage)
publishes the current one (about 16 MiB):

```bash
D=~/.cache/go-ios/ddi/Xcode_iOS_DDI_Personalized/Restore
mkdir -p "$D"
for f in BuildManifest.plist Image.dmg Image.dmg.trustcache; do
  curl -fL -o "$D/$f" "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/$f"
done
```

To verify the download, compare each file's `git hash-object` with the `sha`
GitHub lists for it (`gh api repos/doronz88/DeveloperDiskImage/contents/PersonalizedImages/Xcode_iOS_DDI_Personalized`).

Check that the image supports your device. This prints `True` when the device's
product type is in the manifest:

```bash
python3 -c 'import plistlib,sys; print(sys.argv[2] in plistlib.load(open(sys.argv[1],"rb"))["SupportedProductTypes"])' \
  "$D/BuildManifest.plist" "$(ideviceinfo -k ProductType)"
```

Very new devices may only accept the separate *Cryptex* variant of the image;
this guide covers only the personalized variant.

`scripts/ipad mount-ddi` has Apple's signing server (`gs.apple.com`) personalize
the image for the device, then mounts it. The mount lasts until the iPad
restarts. Many Linux trust stores lack the **Apple Root CA** that anchors
`gs.apple.com`, so go-ios fails with `x509: certificate signed by unknown
authority`. The helper fetches the CA once from apple.com, pins it to its
published SHA-256 fingerprint, stores it in `~/.config/go-ios/apple-root.pem`,
and passes it to go-ios through a private `SSL_CERT_FILE` bundle. The system
trust store is never changed.

### 3. WebDriverAgent

Use Appium's unsigned device build of
[WebDriverAgent](https://github.com/appium/WebDriverAgent/releases), packaged as
an `.ipa`. xtool signs it with your Apple ID, as it does the app:

```bash
mkdir -p /tmp/wda/Payload && cd /tmp/wda
gh release download --repo appium/WebDriverAgent --pattern WebDriverAgentRunner-Runner.zip
bsdtar -xf WebDriverAgentRunner-Runner.zip -C Payload
rm -rf Payload/WebDriverAgentRunner-Runner.app/PlugIns/*.dSYM
zip -qry ~/.cache/go-ios/WebDriverAgentRunner.ipa Payload
xtool install --usb ~/.cache/go-ios/WebDriverAgentRunner.ipa
```

It installs as `XTL-<TEAMID>.com.facebook.WebDriverAgentRunner.xctrunner`, and
the helper finds it by that suffix. Like the app, a free-account signature
expires after **7 days**: re-run the `xtool install` line, then trust the
developer again on the iPad if asked
([building-on-linux.md §8](building-on-linux.md#8-trust-the-app-on-the-device)).

### 4. On the iPad

**Settings → Developer → Enable UI Automation.** Without it, WebDriverAgent
fails with `Timed out while enabling automation mode`. Keep the iPad unlocked
when WDA starts; iOS may ask for the passcode to allow automation mode.

## Everyday use

```bash
scripts/ipad tunnel          # terminal 1; Ctrl-C to stop
scripts/ipad mount-ddi       # once after each iPad restart (only for WDA commands)
scripts/ipad wda             # terminal 2; Ctrl-C stops WDA and its port forward
scripts/ipad status          # tunnel / disk image / WDA
```

Then:

```bash
scripts/ipad launch probe                    # AUv3 Probe (add --restart to relaunch)
scripts/ipad launch aum                      # AUM
scripts/ipad screenshot                      # or: scripts/ipad screenshot out.png
scripts/ipad tree aum                        # every element with its label and frame
scripts/ipad tap "aum sessions" probe        # switch AUv3 Probe's tab
scripts/ipad tap "LAST STATE" aum            # load AUM's last session
```

Where an element has no label, tap or press it by position:

```bash
scripts/ipad size aum                        # e.g. "1210 x 834 points (landscape)"
scripts/ipad tap-at 1030 30 aum              # tap a point
scripts/ipad hold 300 140 aum                # long-press (1.2 s)
scripts/ipad swipe 1100 560 300 560 aum      # drag, e.g. to scroll AUM's mixer
scripts/ipad dtap 930 500 aum                # double-tap (AUM: reset a fader)
scripts/ipad drag 842 426 930 426 930 330 aum  # press, move through points, hold, release
scripts/ipad confirm 1163 137 aum            # two taps 0.5 s apart (two-step buttons)
```

Text entry:

```bash
scripts/ipad type "my name" aum              # clear the first text field, type into it
scripts/ipad fields aum                      # list text fields and their values
scripts/ipad enter aum                       # press Return on the on-screen keyboard
```

`swipe` presses and moves at once, then lets go: right for scrolling, faders and
knobs. `drag` rests 150 ms at each point and holds 1 s before it releases, which
AUM needs for gestures that show something only while the finger is down (a node's
DSP % and latency) or that move things (reordering nodes and channels, moving
windows). `type` works on the *first* text field on screen; check it with `fields`
before you save under that name.

Coordinates are **points** in the app's current orientation, not screenshot
pixels: a screenshot has two pixels per point on Retina iPads, so halve its pixel
coordinates. Apps rotate with the iPad, so check `size` and take a fresh screenshot
before tapping by position. `tap-at` can hit anything: screenshot first near
controls that delete or overwrite.

`tap`, `tap-at`, `hold`, `swipe`, `size`, and `tree` take the app as their last
argument: `probe`, `aum`, or any bundle ID. Pass it. In iPadOS windowed multitasking
the "active application" is SpringBoard, so without an app the tree is the Home
Screen's. Labels match exactly but case-insensitively, and buttons win over their
own text children. A label that sits on a caption next to an icon, rather than on
the button, taps the caption: `tap` reports success and nothing happens; use
`tap-at` on the icon instead.

Screenshots and trees show session names, network addresses, and other private
rig data. They go to `~/.cache/go-ios/screenshots/` by default; keep them out of
this public repository.

The helper reads these overrides: `GOIOS_HOME` (identity and CA, default
`~/.config/go-ios`), `GOIOS_CACHE` (default `~/.cache/go-ios`), `DDI_DIR`,
`WDA_PORT` (default 8100), `PROBE_BUNDLE_ID`, and `WDA_BUNDLE_ID`.

## App notes

**AUv3 Probe:** installed under the xtool-prefixed bundle ID
(`XTL-<TEAMID>.com.teemow.auv3probe`), which the helper resolves on the device.
Useful labels: the tabs `audio units` and `aum sessions`, `resync`, and one
`inspect <unit name>` button per audio unit.

**AUM** (`com.kymatica.AUM`): the start screen offers `LAST STATE` and
`DEFAULT`; channel titles read `<n>: <plugin name>` (`MIDI <n>` for MIDI strips),
and mute, solo, and record-arm are `MUTE`, `SOLO`, and `REC`. Popovers and side
panels are in `tree aum` too, and their list rows tap by label. Most mixer buttons
and the main menu's icons have no usable label: use `tap-at`.
[aum-ui-map.md](aum-ui-map.md) maps every AUM screen, where it opens from, the
top-bar positions, and the gestures that don't come through automation. To load a
*specific* session without tapping through AUM:

- **AUM's link**, `https://kymatica.com/aum/open/<folder-relative path>.aumproj`,
  which AUv3 Probe opens from its **aum sessions** tab
  ([aum-sessions-tab.md](aum-sessions-tab.md)).
- **MIDI Session Load**: a program change that triggers AUM's global Session
  Load action, from a session with ProbeMidiBrain routed to MIDI Control
  ([aum-control-surface.md](aum-control-surface.md)).

## How it works (and the traps the helper handles)

- **The tunnel.** iOS 17+ serves launch, screenshots, and testing only over an
  encrypted RemoteXPC tunnel. `ios tunnel start --userspace` opens it without
  root. Check it with `ios tunnel ls`; the userspace tunnel serves nothing on
  go-ios's default info port 28100.
- **WebDriverAgent** is an XCTest runner. `ios runwda` starts it through
  testmanagerd, and `ios forward 8100 8100` exposes its HTTP API on localhost.
  The helper talks to that API directly: it opens a session, finds elements with
  a predicate on `label`, and clicks them.
- **Session capabilities.** Each WDA command opens a session bound to the app with
  `bundleId` plus `forceAppLaunch: false` (bring a running app forward; don't
  relaunch it) and `shouldTerminateApp: false`. WDA's default **kills the app
  when the session ends**: AUM would close and drop its loaded session.
- **No waiting for idle.** Before every action XCTest waits for the app to go idle.
  An endless animation (AUM spins a slot's icon while its node picker is open)
  makes each tap wait about 45 s. The helper sets WDA's `waitForIdleTimeout` and
  `animationCoolOffTimeout` to 0 in every session.
- **Swipes are W3C touch actions** (down, move over 300 ms, up). WDA's own drag
  endpoint presses before it moves, which AUM reads as a long-press. `drag` is a W3C
  action too, with rests and a final hold.
- **Each action takes about 0.8 s.** The helper opens a WDA session per command, and
  even inside one session a tap takes that long. Two-step buttons that take the
  second tap only for about a second (AUM's CLEAR, OVERWRITE?, TAP TO CONFIRM) need
  `confirm`, which sends both taps in one session; two `tap-at` calls with a
  screenshot or `tree` in between are too slow. For the same reason a tapped-out
  tempo tops out at about 74 BPM.
- **Short-lived menus.** Some popovers close by themselves after a few seconds (AUM's
  AUDIO / MIDI / IMPORT menu on the add-channel tile). Tap the item right after
  opening it; a `tree` in between (several seconds) is too slow.
- **The pasteboard is not readable.** WDA's `getPasteboard` returns an empty value
  for what the app copied (iOS limits pasteboard access to the foreground app), so a
  copied URL cannot be checked from Linux.
- **Plugin windows can hang WDA.** With an Apple AU effect's window open in AUM,
  `tree aum` timed out, and after that every request bound to AUM hung until WDA was
  restarted. go-ios screenshots kept working. Restart `scripts/ipad wda`, close the
  window with `tap-at` on its `✕`, and avoid `tree` while such a window is open.
- **Layout shifts.** AUM's Settings → Show Status Bar moves everything down by about
  32 points; take a fresh screenshot after changing it.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `service 'com.apple.dt.testmanagerd.remote' is not available in RSD` | no (or an outdated) disk image mounted | set up §2, then `scripts/ipad mount-ddi` |
| `x509: certificate signed by unknown authority` from `gs.apple.com` | Apple Root CA missing from the trust store | `scripts/ipad mount-ddi` pins and supplies it |
| `Timed out while enabling automation mode` | UI Automation off, or iPad locked | enable it (§4), unlock, retry `scripts/ipad wda` |
| `tap` reports success, then the app is gone | WDA terminated the app when its session ended | use `scripts/ipad tap` (it sets `shouldTerminateApp: false`) |
| `tree` shows the Home Screen, not the app | session not bound to the app (windowed multitasking) | pass the app: `scripts/ipad tree aum` |
| `tap` reports success, nothing happens | the label is on a caption, not the button | `scripts/ipad tap-at` on the icon |
| `tap-at` hits the wrong control | screenshot pixels used as points, or the iPad rotated | halve pixel coordinates; check `scripts/ipad size aum` |
| every action takes about 45 s | an endless animation and XCTest's idle wait | use `scripts/ipad` (it disables the wait); in your own WDA client set `waitForIdleTimeout` to 0 |
| a two-step button never fires (CLEAR, OVERWRITE?, REMOVE CHANNEL) | the second tap came after the button had reset | `scripts/ipad confirm <x> <y> aum` |
| `WebDriverAgent did not answer within 60 s` | a plugin window with a remote view is open | restart `scripts/ipad wda`, then `tap-at` the window's `✕` |
| `xtool launch`: `DebugserverClient.Error.unknown` | iOS 17+ launch needs the tunnel | `scripts/ipad launch …` |
| `no installed app matching *…` | app not installed, or device not connected | deploy it (`make deploy`) or install WDA (§3) |
