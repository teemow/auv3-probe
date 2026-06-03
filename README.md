# auv3-probe

A throwaway iOS probe utility that enumerates the **AUv3 plugins/synths**
installed on an iPad (or iPhone), dumps each one's `AUParameterTree`, and sends
the result as JSON to the `cmd/auv3-probe` LAN receiver in
[mcp-midi-controller](https://github.com/teemow/mcp-midi-controller).

It mirrors the `widi-probe` / `usb-probe` spikes in that repo: it is a
*measurement tool*, not part of any shipped product. Its output turns the
"convention we invented" parameter tables for AUv3 plugins into **measured**
tables (full parameter list, real ranges/units/`valueStrings`, and
writable/readable flags), which then feed the device-authoring tools.

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

The JSON keys are pinned to the Go `ProbeDump` / `ProbeParam` structs in the
main repo. If those structs change, this app's `ProbeDump.swift` must change
with them — the schema is a small `Codable` mirror, deliberately duplicated
because the two repos are independent.

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
profile is fine for a throwaway probe), and Run.

A build-only sanity check (no signing) is available via:

```bash
make build
```

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
