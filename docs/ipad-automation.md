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
| tap, press, swipe, or read the UI (`tap`, `tap-at`, `hold`, `swipe`, `size`, `tree`, `unlock`, `buy`) | the tunnel **+** a mounted developer disk image **+** WebDriverAgent installed and running **+** UI Automation enabled, iPad unlocked |

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

### When the iPad has locked itself

The iPad locks after its auto-lock time unless the app in front keeps it awake.
AUM does; AUv3 Probe does not, so an iPad left with the probe app in front locks
itself. WebDriverAgent keeps running, but every gesture and app launch then
fails (`Unable to launch … because the device was not, or could not be,
unlocked`), and `curl -s 127.0.0.1:8100/wda/locked` answers `"value" : true`.

Only the passcode unlocks it. Someone who knows it runs, in a terminal:

```bash
scripts/ipad unlock --dry-run   # wake the prompt and find its keys; types nothing
scripts/ipad unlock             # asks for the code (not shown), types it, brings AUM to the front
```

[`scripts/ipad-unlock`](../scripts/ipad-unlock) does the work. It needs
WebDriverAgent running, `curl` and `jq`, and it makes **one** attempt: iPadOS
counts wrong codes and locks the device out after a few, so it types nothing
unless the prompt is empty, the code has the prompt's length and every key it
needs is on screen once, and it stops when a tap does not register. The code is
read from the terminal only: an agent asks a person to run the script and never
types, stores or passes the code itself. The script takes the lock directory
`~/.cache/go-ios/ipad.lock` for as long as it runs and refuses while something
else holds it (`IPAD_LOCK` overrides the path).

### A passcode prompt inside an app

Some screens of an unlocked iPad ask for the passcode before they open, such as
Settings > Face ID & Code. With that prompt in front, someone who knows the code
runs:

```bash
scripts/ipad passcode --dry-run   # find the prompt and its keys; types nothing
scripts/ipad passcode             # asks for the code (not shown), types it into the prompt
```

[`scripts/ipad-passcode`](../scripts/ipad-passcode) follows the same rules as
`unlock`. It reads the code from its own terminal prompt only, makes **one**
attempt, types nothing unless the prompt is empty, the code has the prompt's
length and every key it needs is on screen once (an app's keypad is buttons, and
each button nests a copy of itself), and stops when a tap does not register. It
reports whether the prompt closed (accepted) or stayed (refused, no retry). It
changes no setting itself: whatever comes after the prompt is a separate step.
It refuses on a locked iPad, which is `unlock`'s job. A caller that holds the iPad
lock and opened the prompt sets `IPAD_LOCK_HELD=1`.

When the person is not at the desk's own terminal, an agent can start the
command in a terminal multiplexer session on the host (for example
`tmux new-session -d -s ipad 'IPAD_LOCK_HELD=1 scripts/ipad passcode'`). The person
attaches (`tmux attach -t ipad`), types the code and detaches. The agent reads
only the script's output, never the keystrokes.

### Getting an app from the App Store

`scripts/ipad buy` opens an app's page in the App Store on the iPad and reads it;
with the person's confirmation it buys or downloads that one app (or one App Store
bundle of apps, [below](#an-app-store-bundle)):

```bash
scripts/ipad buy 1234567890                  # or https://apps.apple.com/<cc>/app/<name>/id1234567890
#   name:        Example Synth
#   developer:   Example Audio
#   price:       9,99 €   (button: "9,99 €")
#   in-app purchases: no
#   bundle id:   com.example.synth
#   ...
#   looked only: nothing was bought or downloaded
scripts/ipad buy 1234567890 --confirm-name "Example Synth" --confirm-price "9,99 €"
```

Looking is the default: without both confirmations it taps nothing that buys or
downloads. It prints the app's name, developer and price, whether the page lists
in-app purchases, the bundle id, and either the exact buy command or the reasons a
purchase would be refused. `--confirm-price` takes the price as the look prints it,
`free` for a free app, or `redownload` for an app bought before (the cloud button).

**The confirmation is the person's, not the agent's.** An agent passes
`--confirm-name` and `--confirm-price` only after the person who pays has
confirmed that app and that total in their own words, for this purchase. An
earlier approval does not carry over to another app or another price.

With the confirmations the script

1. refuses, without tapping, when the name or the price differs from the page, when
   the page title is not the name Apple's public lookup gives for the id, when the
   page price differs from the lookup's, on a subscription or any offer it does not
   know (a trial, Arcade, a second offer button), on a notice next to the offer
   ("not compatible with this device"), and on anything it cannot read (developer,
   in-app purchases);
2. reopens the page, checks that it still shows the same, and taps the price, Get
   or re-download button of that app once, found by its identifier and position
   (never another app's button from the "you might also like" shelves);
3. reads what the iPad shows from the accessibility tree (the App Store,
   SpringBoard and whatever is in front) and prints, with the seconds since the
   tap, what the person has to do and each step: the sheet is open, the sheet
   waits for a double-press of the top button, Face ID, a password or a
   sign-in, the purchase went through, the app is downloading, it is
   installed, and a "still waiting" line at least every 20 s;
4. taps the sheet's Buy or Install button once if the sheet shows that app (and,
   for a paid app, that price), and, when the sheet asks for the password, asks
   for it at its terminal prompt then (not before), types it and presses Return,
   once;
5. stops early, with a message, when the sheet closes and the app's button reads
   the price again (nothing was bought), when the App Store shows an error, and
   when no sheet and no download appear within 120 s of the tap (at 45 s it
   prints what the iPad shows and asks the person to look); otherwise it waits (`--timeout`, default 600 s) until
   `ios apps` lists the bundle id and the page's button reads Open. If the iPad
   locks, unlock it so the script can verify Open: an entry in `ios apps` alone
   can still be a download. If the installed-app list cannot be read, the
   purchase status is unknown; the script keeps watching instead of reporting
   that nothing was bought.

```text
[  1 s] tapped "7,99 €" once; reading what the iPad shows (Ctrl-C stops this script, not the purchase)
[  4 s] the iPad shows:
    App kaufen
    Example Synth
    7,99 €
    Account: (hidden)
    Mit Taste bestätigen
[  4 s] ON THE IPAD: press the top button (the power button) twice, quickly, to pay. ...
[ 12 s] the app's button now reads "Wird geladen" (state downloading); the purchase went through, downloading
[ 31 s] installed: Example Synth (com.example.synth)
```

**The double-press needs a person at the iPad; the password does not.** With Face
ID or Touch ID turned on for purchases, the iPad confirms a purchase with a
double-press of the top button ("Zum Zahlen zweimal drücken") and then Face ID, or
Touch ID, or the passcode. Only a person at the iPad can do that: no script and no
agent can press the button. The script says so and waits. Apple closes the sheet
after about a minute, and the script then reports that nothing was bought.

AssistiveTouch does not change that. Tried on iPadOS 27 with AssistiveTouch on
(Settings > Accessibility > Touch > AssistiveTouch): WebDriverAgent can tap its
floating button and open its menu, but neither the menu (with the sheet open: the
top level, Device and Device > More) nor the list of custom actions offers a
double-click, and the sheet kept "Zum Zahlen zweimal drücken" until it closed
unpaid. The menu is not in any accessibility tree either.

**To buy without anyone at the iPad**, the person who owns it turns off Face ID
for purchases once: Settings > Face ID & Code > "Use Face ID for" > "iTunes & App
Store" ("Face ID verwenden für" > "iTunes & App Store"). Settings asks for the
passcode first; `scripts/ipad passcode` types it from the person's own prompt
([above](#a-passcode-prompt-inside-an-app)). Only that switch changes; turning it
back on is the person's call. With it off, the purchase sheet (SpringBoard's,
button `pay-now`, "Kauf") has a plain button that the script taps once after
checking app and price, and then asks for the Apple ID password, which the person
types at the script's prompt. After the first password Apple asks once whether
later purchases need it too ("Passwort für weitere Käufe auf diesem Gerät
erfordern?"). The script answers only "Immer anfordern" (Always Require), the
stricter choice, and never the 15-minute option. Tested end to end on iPadOS 27.2
for a paid app: tap, Kauf, password, the question, download, installed, in about
a minute.

A person who is not at the desk's own terminal can reach the prompts through a
terminal multiplexer session an agent starts on the host, as for `passcode`:

```bash
tmux new-session -d -s ipad 'scripts/ipad unlock && scripts/ipad buy 1234567890 --confirm-name "Example Synth" --confirm-price "9,99 €"'
tmux attach -t ipad    # the person: the code, then the password; Ctrl-b d detaches
```

Two things learned live. The person has to be at the prompt within a few minutes
of the tap: the App Store does not keep the iPad awake, and once it locks the
password can no longer be typed (the script then clears the field and sends
nothing). And attaching can deliver a stray Return, so an empty answer is asked
once more before the script leaves the password to the iPad.

While the sheet is open the app's button already reads "Download vorbereiten"
(state `loading`). That says nothing about payment: the script reports a purchase
only on a later state or when the sheet closes and the button does not read the
price again.

**The password comes only from a person at the script's own prompt**, as the
passcode does for `unlock`. It is not echoed, stored or logged, and never taken
from an argument, the environment, a file or a pipe; without a terminal the script
does not ask and stops at the sheet. An agent never asks for it in chat and never
types, stores or passes it: it asks the person to run the buy command in a terminal
on the host the iPad is plugged into. The script makes **one** attempt: when the
sheet asks again, it stops, because Apple locks an account after wrong passwords.
Return alone at the prompt (asked twice, since attaching a terminal can send one)
leaves the password to be typed on the iPad.

It does not type a verification code or an account name: it says that the person
does that step on the iPad and waits. It stops and leaves the sheet as it is on a
sheet without exactly one Buy or Install button, or one that does not show the app
and its price. It never buys in-app purchases or subscriptions and changes no
account, payment, password or App Store setting beyond answering Apple's own
question with "always require". The Apple Account the sheet shows
is printed as "(hidden)". WebDriverAgent keeps a single session, so the script
reads SpringBoard and the other apps through the App Store's session (by pointing
its `defaultActiveApplication` at them), never by opening a second one, which
would end the first.

It needs WebDriverAgent and the tunnel, and an unlocked iPad. It takes the lock
directory `~/.cache/go-ios/ipad.lock` like `unlock` does; a caller that holds the
lock already sets `IPAD_LOCK_HELD=1`. The country for the lookup comes from the URL,
else the iPad's region; `--country <cc>` overrides it. Afterwards it brings AUM to
the front. The page is read from the accessibility tree: the top lockup's
`AppStore.shelfItemSubComponent.title`, `AppStore.offerButton[state=…]` and its
subtitle (In-App Purchases), and the Information section's in-app purchases row,
which the script scrolls to. Button words are matched for English and German, and for French, Spanish
and Italian for the common buttons; where a word is not known it refuses rather than guesses.

#### An App Store bundle

A bundle (several apps from one developer at one price, a URL with `/app-bundle/`)
is looked at and bought the same way, as one purchase with one confirmation: the
bundle's name and price.

```bash
scripts/ipad buy https://apps.apple.com/de/app-bundle/example-bundle/id1234567890
#   bundle:      1234567890 (an App Store bundle of 2 apps, one purchase)
#   name:        Example Bundle
#   price:       29,99 €   (button: "29,99 €")
#   apps in it:
#     Example Synth: 22,99 € alone (button "22,99 €"), bundle id com.example.synth, in-app purchases: no
#     Example Drums: 12,99 € alone (button "12,99 €"), bundle id com.example.drums, in-app purchases: no
#   bundle page: Example Bundle by Example Audio, 29,99 € (the apps alone: 35,98 €)
#   to buy it, after the person who pays has confirmed this bundle and this price:
#     scripts/ipad buy https://apps.apple.com/de/app-bundle/id1234567890 --confirm-name 'Example Bundle' --confirm-price '29,99 €'
```

A bare id that Apple's lookup does not know is tried as a bundle. What differs
from a single app:

- **Where the cross-check comes from.** Apple's lookup has no entry for a bundle.
  The bundle's name, price, developer and apps come from Apple's public web page of
  the bundle (`apps.apple.com/<cc>/app-bundle/id<id>`, the data its web app renders
  from), which is sent the id and the country and nothing else. Each app in the
  bundle is then looked up by its id, and the lookup's name and bundle id must
  match the bundle page's.
- **What the iPad shows.** The bundle page lists its apps as rows
  (`AppStore.shelfItem.smallLockup[id=<app id>,parentId=bundleChildren,…]`, "2 Apps
  in diesem Paket"), each with its own button. The script refuses when the rows are
  not exactly the apps of Apple's bundle page.
- **Only at the bundle's price, only while none of its apps is had.** When the
  person has bought or installed one of the apps already, the App Store asks a
  reduced "complete my bundle" price that no public source confirms, so the script
  refuses and says to get the other apps one by one. A bundle bought before is not
  re-downloaded as a bundle either.
- **When it is done.** The bundle's own button never reads Open: after the
  purchase it reads "Gekauft" (state `purchased`). The script waits until `ios
  apps` lists every app of the bundle and every app's row on the bundle page
  reads Open, and reports each row's progress on the way. "Nothing was bought"
  needs the bundle's button and every row as before the tap and none of the apps
  listed.

Tested end to end on iPadOS 27 for a two-app bundle, with Face ID off for
purchases and the password typed at the script's prompt:

```text
[  0 s] tapped "29,99 €" once; reading what the iPad shows (Ctrl-C stops this script, not the purchase)
[  4 s] the bundle's button now reads "Download vorbereiten" (state loading); the App Store waits for the purchase sheet
[  8 s] the iPad shows:
    Example Bundle 4+
    App-Paket kaufen
    29,99 €
    Einmalige Gebühr
    Account: (hidden)
[  8 s] confirmed the purchase sheet once (it showed this bundle and this price)
[ 17 s] the iPad shows:
    Gib das Passwort für (hidden) ein, um diese Transaktion zu autorisieren.
    (account hidden)
    Bestätigen
The sheet asks for the Apple ID password. Type it here (not shown; Return alone to type it on the iPad instead):
[ 33 s] password entered once; waiting for the App Store
[ 47 s] the sheet has closed; the bundle is downloading
[ 50 s] the bundle's button now reads "Gekauft" (state purchased); the purchase went through, downloading
[ 50 s] "Example Synth" now reads "Wird geladen: 19,2 MB von 122,8 MB (5 MB/Sek.)" (state downloading)
[ 62 s] "Example Drums" now reads "Öffnen" (state open)
[ 68 s] installed: Example Bundle (com.example.drums, com.example.synth)
```

The sheet's Buy button (on the "App-Paket kaufen" sheet) is tapped only when
the sheet shows the bundle's name and price; otherwise the script stops and
leaves the sheet to the person. The password sheet names the account as "<name>,
<address>"; the script prints that line as "(account hidden)".

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
| `Unable to launch … because the device was not, or could not be, unlocked`; `/wda/locked` is true | the iPad locked itself (AUv3 Probe or SpringBoard was in front) | `scripts/ipad unlock` in a terminal, by someone who knows the passcode ([above](#when-the-ipad-has-locked-itself)) |
| `tap` reports success, then the app is gone | WDA terminated the app when its session ended | use `scripts/ipad tap` (it sets `shouldTerminateApp: false`) |
| `tree` shows the Home Screen, not the app | session not bound to the app (windowed multitasking) | pass the app: `scripts/ipad tree aum` |
| `tap` reports success, nothing happens | the label is on a caption, not the button | `scripts/ipad tap-at` on the icon |
| `tap-at` hits the wrong control | screenshot pixels used as points, or the iPad rotated | halve pixel coordinates; check `scripts/ipad size aum` |
| every action takes about 45 s | an endless animation and XCTest's idle wait | use `scripts/ipad` (it disables the wait); in your own WDA client set `waitForIdleTimeout` to 0 |
| a two-step button never fires (CLEAR, OVERWRITE?, REMOVE CHANNEL) | the second tap came after the button had reset | `scripts/ipad confirm <x> <y> aum` |
| `WebDriverAgent did not answer within 60 s` | a plugin window with a remote view is open | restart `scripts/ipad wda`, then `tap-at` the window's `✕` |
| `xtool launch`: `DebugserverClient.Error.unknown` | iOS 17+ launch needs the tunnel | `scripts/ipad launch …` |
| `no installed app matching *…` | app not installed, or device not connected | deploy it (`make deploy`) or install WDA (§3) |
