# auv3-probe

The **iPad node** in the [mcp-midi-controller](https://github.com/teemow/mcp-midi-controller)
rig ecosystem. It began as a throwaway AUv3 measurement spike — that framing is
now retired. It is the permanent presence on the iPad: the only component that
can reach *inside* iOS and AUM, where the laptop and the pedals cannot.

`mcp-midi-controller` is the **orchestrator** (laptop, design-time). Around it:

- **auv3-probe** (this app) — the **iPad node**: sees the installed AUv3
  plugins, the AUM sessions, and eventually runs *inside* AUM itself.
- **[ble-midi-footswitch](https://github.com/teemow/ble-midi-footswitch)**
  ("threefoot") — the **intelligence on the pedalboard**: a standalone, offline
  scene/song player.
- **[rig-capture](https://github.com/teemow/rig-capture)** — the **macOS capture
  tool**: reverse-engineers vendor editor protocols over the USB-attached pedals.

## What it does (and will do)

Today it enumerates the **AUv3 plugins/synths** installed on the iPad (or
iPhone), dumps each one's `AUParameterTree`, and sends the result as JSON to the
LAN probe receiver in mcp-midi-controller. That output turns the "convention we
invented" parameter tables for AUv3 plugins into **measured** tables (full
parameter list, real ranges/units/`valueStrings`, and writable/readable flags),
which feed the device-authoring tools.

Its remit is growing into the iPad's permanent role in the rig:

1. **Probe AUv3 plugins** — enumerate + dump parameter trees (shipping today;
   the rest of this README documents it).
2. **Read/write AUM projects** — move `.aumproj` sessions on/off the device over
   the LAN so the orchestrator's Go `internal/aum` library can read, diff, and
   author them. The iPad owns the file I/O; the laptop owns the format.
3. **Run inside AUM** — ship as an AUv3 extension so the app lives *in* the host,
   not just beside it.
4. **Assist "threefoot"** — help the pedalboard footswitch load scenes or songs.

## What it produces

One `ProbeDump` JSON document per plugin, matching the schema consumed by the
`import_auv3_probe` MCP tool in the main repo:

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

Dumps also carry richer optional metadata: `component.manufacturerName` /
`version`, `shortName`, `factoryPresets`, and per-parameter `group`, `flags`,
and decoded flags (`displayLogarithmic`, `isHighResolution`, …). `min`/`max`/
`value` are always finite — AU `±Inf`/`NaN` values are clamped and noted in
`nonFinite`. See [docs/design.md](docs/design.md#schema-contract-probedump) for
the full schema.

The JSON keys are pinned to the Go `ProbeDump` / `ProbeParam` structs in the
main repo. If those structs change, this app's `ProbeDump.swift` must change
with them — the schema is a small `Codable` mirror, deliberately duplicated
because the two repos are independent.

At the end of a run the app also POSTs a **diagnostics report** to
`/auv3-probe/diagnostics` recording every outcome (sent / empty / failed), so
plugins that fail to instantiate — which never produce a dump — are still
recorded on the receiver instead of being lost in the app UI. The receiver
stores it under `_diagnostics/<timestamp>.json`.

## Discovering third-party plugins

The app declares the **Inter-App Audio** capability (`inter-app-audio` in
`Resources/AUv3Probe.entitlements`). This is **required**: without it
`AVAudioUnitComponentManager` only returns Apple's built-in Audio Units and
hides every third-party AUv3. It works with a free Apple ID. See
[docs/auv3-discovery.md](docs/auv3-discovery.md) for the full explanation.

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
4. Select the plugins to probe and tap **Probe & Send**. Each dump is POSTed to
   `/auv3-probe`. If the receiver is unreachable, use **Save to Files** to export
   the JSON for manual transfer.

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
