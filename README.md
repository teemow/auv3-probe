# auv3-probe

The **iPad node** in the [mcp-midi-controller](https://github.com/teemow/mcp-midi-controller)
rig ecosystem. It began as a throwaway AUv3 measurement spike — that framing is
now retired. It is the permanent presence on the iPad: the only component that
can reach *inside* iOS and AUM, where the laptop and the pedals cannot.

`mcp-midi-controller` is the **orchestrator** (laptop, design-time). Around it:

- **auv3-probe** (this app) — the **iPad node**: sees the installed AUv3
  audio units, the AUM sessions, and eventually runs *inside* AUM itself.
- **[ble-midi-footswitch](https://github.com/teemow/ble-midi-footswitch)**
  ("threefoot") — the **intelligence on the pedalboard**: a standalone, offline
  scene/song player.
- **[rig-capture](https://github.com/teemow/rig-capture)** — the **macOS capture
  tool**: reverse-engineers vendor editor protocols over the USB-attached pedals.

## What it does (and will do)

Today it enumerates the **AUv3 audio units** (instruments/effects) installed on
the iPad (or iPhone), reads each one's `AUParameterTree`, and sends the result as
JSON to the LAN receiver in mcp-midi-controller. That output turns the
"convention we invented" parameter tables for AUv3 units into **measured** tables
(full parameter list, real ranges/units/`valueStrings`, and writable/readable
flags), which feed the device-authoring tools. It also ferries **AUM sessions**
(`.aumproj`) to and from the orchestrator.

Its remit is growing into the iPad's permanent role in the rig:

1. **Read AUv3 audio units** — enumerate + read parameter/preset trees (shipping;
   the rest of this README documents it).
2. **Read/write AUM sessions** — move `.aumproj` files on/off the device over the
   LAN so the orchestrator's Go `internal/aum` library can read, diff, and author
   them (shipping). The iPad owns the file I/O; the laptop owns the format.
3. **Run inside AUM** — ship as **two AUv3 app extensions** so the app lives *in*
   the host process, not just beside it (in progress):
   - **ProbeMidiBrain** (`aumi`) — a MIDI processor that drives scene/session
     changes from the song structure (host transport) and the "threefoot"
     footswitch.
   - **ProbeAudioTap** (`aufx`) — a transparent audio tap that streams downsampled
     PCM + RMS/peak to the orchestrator, giving an AI agent "ears".

   See [docs/auv3-extension.md](docs/auv3-extension.md).
4. **Assist "threefoot"** — help the pedalboard footswitch load scenes or songs
   (ProbeMidiBrain is the first step toward this).

## What it produces

One `AudioUnitDetails` JSON document per audio unit, matching the schema consumed
by the `import_auv3_probe` MCP tool in the main repo:

```json
{
  "component": { "type": "aumu", "subtype": "iSEM", "manufacturer": "Artu" },
  "name": "Arturia iSEM",
  "parameters": [
    {
      "address": 0,
      "keyPath": "cutoff",
      "identifier": "cutoff",
      "displayName": "Cutoff",
      "min": 0.0, "max": 1.0,
      "unit": "generic", "unitName": null,
      "valueStrings": null,
      "writable": true, "readable": true,
      "value": 0.5
    }
  ]
}
```

Records also carry richer optional metadata: `component.manufacturerName` /
`version`, `shortName`, `factoryPresets`, and per-parameter `group`, `flags`,
and decoded flags (`displayLogarithmic`, `isHighResolution`, …). `min`/`max`/
`value` are always finite — AU `±Inf`/`NaN` values are clamped and noted in
`nonFinite`. See
[docs/design.md](docs/design.md#schema-contract-audiounitdetails) for the full
schema.

The JSON keys are pinned to the Go `device.ProbeDump` / `device.ProbeParam`
structs in the main repo. If those structs change, this app's
`AudioUnitDetails.swift` must change with them — the schema is a small `Codable`
mirror, deliberately duplicated because the two repos are independent.

At the end of a run the app also POSTs a **scan report** to
`/auv3-probe/diagnostics` recording every outcome (sent / empty / failed), so
units that fail to instantiate — which never produce details — are still recorded
on the receiver instead of being lost in the app UI. The receiver stores it under
`_diagnostics/<timestamp>.json`.

## Discovering third-party audio units

The app declares the **Inter-App Audio** capability (`inter-app-audio` in
`Resources/AUv3Probe.entitlements`). This is **required**: without it
`AVAudioUnitComponentManager` only returns Apple's built-in Audio Units and
hides every third-party AUv3. It works with a free Apple ID. See
[docs/auv3-discovery.md](docs/auv3-discovery.md) for the full explanation.

## Running inside AUM (AUv3 extensions)

The app ships two AUv3 app extensions hosted by the container app:
**ProbeMidiBrain** (a `aumi` MIDI processor that emits scene-change MIDI from the
song structure + footswitch) and **ProbeAudioTap** (a `aufx` transparent tap that
streams PCM + features to `mcp-midi-controller`). The sources live in
`Sources/ProbeMidiBrain/` and `Sources/ProbeAudioTap/`, with shared code in
`Sources/ProbeKit/`. Both build paths below produce the app with the two
`.appex` plugins embedded. AUM routing recipes, the realtime-safety model, and
the audio-stream wire contract are in
[docs/auv3-extension.md](docs/auv3-extension.md).

Hosted inside AUM the brain can reach almost AUM's **entire** control surface over
MIDI — what it can read and change is measured in
[docs/aum-control-surface.md](docs/aum-control-surface.md). That power is only as
good as the loaded session, so the larger vision (deep session understanding + a
**standard MIDI-control mapping** so the brain can change scenes) lives in the
orchestrator repo:
[mcp-midi-controller / aum-brain-control.md](https://github.com/teemow/mcp-midi-controller/blob/main/docs/aum-brain-control.md).

## Building (on a Mac)

The repo is edited on Linux but built on macOS. The Xcode project is
**generated** from `project.yml` with [XcodeGen](https://github.com/yonik/XcodeGen)
and is gitignored, so you generate it locally before building.

```bash
brew install xcodegen
make generate          # runs `xcodegen generate` -> AUv3Probe.xcodeproj
open AUv3Probe.xcodeproj
```

In Xcode: select your iPad, set your personal team (the free 7-day provisioning
profile is fine for local development), and Run.

A build-only sanity check (no signing) is available via:

```bash
make build
```

## Building (on Linux, no Mac)

You can also build, sign, and install straight from Linux with a free Apple ID
using [xtool](https://github.com/xtool-org/xtool) — useful when no Mac can
target the device's iOS version. The in-repo `Package.swift` / `xtool.yml` reuse
the same `Sources/`, and the Makefile drives it:

```bash
make devices       # confirm the device is connected (usbmuxd)
make deploy        # build -> sign -> install -> launch over USB
```

See [docs/building-on-linux.md](docs/building-on-linux.md) for the one-time setup
this assumes (Swift toolchain ⇄ SDK version matching, `xtool sdk install`,
`xtool auth login`), plus the Inter-App Audio entitlement, the free-account
7-day certificate limit, and LAN/firewall notes. `make help` lists all targets.

## Running against the receiver

1. Start `cmd/auv3-probe` from the main repo on a host on the same LAN; it binds
   `:7800` by default.
2. Launch this app on the iPad. iOS will prompt for **local network** access —
   allow it (the app POSTs over the LAN).
3. Enter the receiver's `host:port` in the app (it is **not** committed anywhere
   — you type it at runtime), tap **Test connection** (hits `/healthz`).
4. Select the audio units to read and tap **Read & Send**. Each record is POSTed
   to `/auv3-probe`. If the receiver is unreachable, use **Save to Files** to
   export the JSON for manual transfer.

## Reading AUM sessions

The **aum sessions** tab reads AUM project files (`.aumproj`) and standalone MIDI
mappings (`.aum_midimap`) **entirely on-device — no daemon required**. The app
decodes the NSKeyedArchiver binary plist itself (`Sources/BinaryPlist.swift` +
`Sources/AUMSessionParser.swift`, a read-only Swift port of the Go
`internal/aum` library in
[mcp-midi-controller](https://github.com/teemow/mcp-midi-controller)) and renders
the parsed structure — version, tempo, channels, plugin nodes (with their AUv3
component identity) and assigned MIDI mappings.

There are two ways to get a session into the inspector — they differ only in
whether the app *remembers* where to look:

- **link aum folder** — a *persistent* link. Tap it once and pick AUM's own
  folder (e.g. *On My iPad/AUM*). The app stores a **security-scoped bookmark**
  and from then on lists **every** `.aumproj` / `.aum_midimap` in that folder, so
  you can inspect any of them with one tap (and, with a host, upload them). This
  is also what enables dialog-free **write-back** into AUM.
- **open file** — a *one-off*. Pick a single session/mapping to inspect right
  now; nothing is remembered and no folder is linked.

Either way the file is parsed locally and rendered: version, tempo, channels,
plugin nodes (with their AUv3 component identity) and assigned MIDI mappings.

iOS has no entitlement that grants blanket access to another app's documents, so
the user-driven picker or the one-time folder bookmark is the only sanctioned
path. The bookmark is stored on-device only.

### Optional: the mcp-midi-controller ferry

When an `mcp-midi-controller host:port` is set in the top bar (and **Test
connection** passes), an optional ferry appears:

- **Upload** device sessions to mcp-midi-controller (`POST /aum-session`, verbatim
  bytes) — per file or **upload all** from the linked folder.
- **mcp-midi-controller files**: list and pull files it holds (`GET /aum-session`)
  back into AUM. With a folder linked they are written **straight into it**;
  otherwise the **share sheet** opens ("Open in AUM" / "Save to Files…"). Rows
  can also be inspected — the app downloads the bytes and parses them on-device.

Run the receiver from the mcp-midi-controller repo with
`go run ./cmd/auv3-probe` (or the full daemon, `cmd/mcp-midi-controller`). The
standalone command seeds a synthetic `template.aumproj` into its staging dir on
first run, so the list has something to test with before you upload anything.

The ferry is purely additive — listing and inspecting always work offline.

> **Privacy.** Session files carry installation-specific data (song/channel
> names). They are parsed and shown on-device; when the ferry is used they travel
> only between the device and your own mcp-midi-controller on the LAN. The app
> never logs or commits filenames, paths, or hostnames.

## CI

`.github/workflows/ci.yaml` runs a build-only check on a GitHub-hosted
`macos-latest` runner (free for public repos): it installs XcodeGen, generates
the project, and runs `xcodebuild ... build CODE_SIGNING_ALLOWED=NO`. It does
not depend on any personal machine. If you later want CI to sign and install to
a device, add a self-hosted macOS runner.

## Public-repo rule

This is a public repo. No real hostnames, IP addresses, or device names belong
in committed code — the receiver host is entered at runtime and never persisted
to git.

## License

MIT
