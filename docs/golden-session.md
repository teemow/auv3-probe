# Golden full-control sessions — the banking convention

A **golden** session is one where *every* mappable AUM target has a
collision-free MIDI trigger: the mixer strips, transport and system actions,
every hosted node's reserved triggers (bypass / show / front), and every one of
its writable parameters. The brain can then reach the whole
[measured control surface](aum-control-surface.md) of that session over a single
LAN channel, with no hand-wiring.

The earlier single-channel `Convention` (mixer + transport + one CC per node
param, all on one channel, node CCs restarting per node) collapses on a
multi-node session: two nodes' first params both land on the same CC, so one
message drives several parameters. The **banking allocator**
(`mcp-midi-controller/internal/aum/instrument.go`) fixes that by spreading
targets across MIDI channels while keeping the mixer/transport convention CCs
exactly where a session-derived mixer **device type** expects them.

> Public-repo rule: this file carries no installation-specific data (hostnames,
> rig inventory, band/session names). The worked numbers come from the committed
> generic example and from capability counts, never from a private rig.

## The address space

Per MIDI channel the allocator has **256 targets**:

- **128 CC** (`specState` type 0, `data1` 0–127) — filled first.
- **128 Note** (`specState` type 1, `data1` 0–127) — the overflow space, used
  only once a channel's CCs are full (and only when `use_notes` is on).

Program Change (`type 2`) is a separate per-channel space used for
`PresetLoadCtrl` triggers on the global channel.

## Channel layout

- **Global / convention channel** (default **send ch 1**, stored `0`) carries:
  - **Transport** actions wired to `device.ConventionTransportCC` (Toggle Play
    CC 20, Start/Stop/Rewind/Record/Tap = 102–105/108), so they stay aligned
    with `BrainControlConvention` in the iPad app
    ([`Sources/ProbeKit/SongStructure.swift`](../Sources/ProbeKit/SongStructure.swift)).
  - The remaining **Transport** targets (Previous/Next bar, Tempo, Metronome)
    and the **System** actions (`_AUM:ShowSelf/HideAllPlugins/UnSoloAll`) on the
    next free CCs of the global channel.
  - Any node `_AUMNode:PresetLoadCtrl/*` as Program Change.
  - The **non-master audio strips' Channel controls** (Volume/Mute/Solo/Rec) on
    their `device.ConventionMixerCC` band (Mute `18+3n`, Volume `19+3n`, Solo
    `44+n`, Rec `52+n` for audio ordinal `n`).
- **Banked pool** (default from **send ch 2** upward, `start_channel`): every
  other target, allocated sequentially — CC 0..127, then Note 0..127, then the
  next channel — up to channel 16.

Keeping the mixer/transport CCs on the convention band is what lets the
session-derived **AUM mixer device type** (`aum.MixerDeviceType`) still resolve
after instrumenting: it reads strip controls from `device.ConventionMixerCC` and
the transport block from `device.ConventionTransportCC`, so a golden session and
its derived mixer device agree by construction.

## Priority order

Allocation runs by priority class so the musically essential controls are never
starved by dense FX:

1. **Global** — Transport (convention CCs first), System, PresetLoadCtrl (PC),
   on the global channel.
2. **Mixer strips** — non-master audio Volume/Mute/Solo/Rec on the convention
   band (global channel).
3. **Banked pool** (ch 2+), in order:
   1. Non-convention strip targets (`ScrollToChannel`, MIDI-strip and master
      Mute/Solo) — these have no convention CC.
   2. Node reserved triggers (`_AUMNode:Bypass/FrontPlugin/TogglePlugin`).
   3. **Instrument** node params (component type `aumu`).
   4. **Effect** node params (`aufx`/`aumf`, and anything else).

So strips, transport, instruments and bypass are guaranteed addresses; only deep
FX parameters of a FabFilter-heavy rig spill late or overflow.

## Overflow, preserve, and play-channels

- **Overflow is a warning, not a fatal error.** When channel 16 is exhausted the
  remaining targets stay unassigned placeholders and are listed in the report.
  For an exhaustive FabFilter-heavy session this is by design — the priority
  order guarantees the essentials are covered.
- **`preserve_existing` (default true)** leaves every already-enabled mapping
  untouched and marks its `(channel, space, number)` occupied, so new
  assignments route around hand-made and prior-run mappings. This makes
  re-instrumenting **safe and idempotent**: run it twice and the second run
  assigns nothing new. It is also how you layer full control on top of a session
  that was hand-mapped on the iPad — the convention channel is seeded from the
  session's existing `ConventionChannel()` so it stays stable. (If a hand mapping
  already sits on a convention CC, that convention target is reported as overflow
  rather than colliding.)
- **`play_channels`** excludes the given channels from Note allocation (their CC
  space is still used). A control **Note** also reaches any instrument the brain
  plays on that channel, so exclude the channels an instrument listens on to keep
  control Notes from sounding.

## Routing caveat (Notes as control)

Notes are the overflow space, not the first choice: a Note control message routed
into AUM's MIDI Control will also reach any instrument on that channel. Mitigate
by (a) preferring CC (the default — Notes are only used once CCs are full), (b)
using `play_channels` to keep Notes off instrument channels, and (c) routing
control to AUM **MIDI Control** only.

## Tools

All in `mcp-midi-controller`'s MCP surface (`internal/mcpserver/aum_tools.go`):

- **`instrument_aum_session`** — bank an existing staged session collision-free
  and re-stage it (default `out_id` `<session>_golden`). Args: `global_channel`,
  `start_channel`, `use_notes`, `play_channels`, `preserve_existing`, `dry_run`.
  This is also the **"update an existing session"** tool: run with
  `preserve_existing:true` to add full control on top of a hand-mapped session.
  With **`add_probes:true`** (plus `host`, optional `tap_channel`) it also
  **embeds the rig** — see below — so the staged golden session is self-contained.
- **`author_aum_session` `full_control:true`** — author a multi-node session and
  bank it instead of applying the single-channel convention.
- **`author_probe_session`** — bootstrap a minimal probe rig in one call (a MIDI
  strip with `ProbeMidiBrain`, an audio strip with `ProbeAudioTap`, a master),
  brain MIDI OUT → AUM MIDI Control, brain/tap configured for the daemon host;
  `full_control:true` banks it.

## Embedding the rig: a self-contained golden session

Banking alone makes every target *addressable*, but the mappings stay dormant
until something emits those CCs/Notes into AUM's **MIDI Control** and something
streams the audio back. In an authored rig that "something" is the
`ProbeMidiBrain` + `ProbeAudioTap` nodes; a **real uploaded session has neither**.
So instrumenting an uploaded session with `add_probes:true` first **injects the
rig in place** (`Session.AddProbeRig`, `internal/aum/probe_rig.go`) before
banking:

- **Hands.** A new `AUMMIDIStrip` hosting `ProbeMidiBrain` is appended at the end
  of the channel list, and a `brain MIDI OUT → BuiltIn:MIDI Control` wire is
  **merged** into the existing `midiMatrixState` — merged, never replaced, so the
  session's own MIDI routing (its MIDI processors feeding its instruments)
  survives untouched.
- **Ears.** `ProbeAudioTap` is inserted as an appended slot on `tap_channel`'s
  node chain (the same-channel insert from
  [aum-midi-matrix.md](https://github.com/teemow/mcp-midi-controller/blob/main/docs/research/aum-midi-matrix.md)),
  so audio flows through it with no cross-channel bus authoring. Pick the channel
  of the instrument you want to hear.
- **No host to configure.** Both plugins find the daemon via **Bonjour**
  (`DaemonDiscovery`): the brain's control channel starts unconditionally on load
  and the tap auto-streams (`streaming:true`), so a loaded golden session
  connects itself — nothing to add or wire on the iPad.

Appends keep the position-aligned `channels[]` / `nodeArchives[]` arrays in
lockstep and add the matching `midiCtrlState` `chan<idx>` / `slot<n>` catalogue
entries, so the banking allocator then banks the new strip/slot like any other
target and the result round-trips (`decode(encode(x))`).

## Downstream: a golden session becomes devices

A fully-instrumented session is what makes every node parameter addressable, so
`discover_devices` / `import_aum_session` can **auto-create device instances**:
one session-derived AUM mixer **device** (its strips taken from the live session)
plus one **device** per hosted AUv3 node, each on its matrix-derived MIDI channel,
all speaking the `auv3midi` transport (the brain re-emits the convention CCs into
AUM's MIDI Control over the LAN channel). The device **types** are generated from
the session / the matched AUv3 probe. From there an agent drives the rig — and
**scenes** recall sets of device-control values — without touching AUM by hand.

## Worked examples

- **Generic, committed** — [`docs/examples/golden-example.aumproj`](examples/golden-example.aumproj)
  and its decoded [`golden-example-midi-control.json`](examples/golden-example-midi-control.json):
  a clean rig (brain on a MIDI strip; iSEM + a delay + `ProbeAudioTap` on one
  audio strip; master), instrumented full-control. 51 mappings on 2 channels, no
  overflow: transport + mixer + system on the convention channel (ch 0), node
  params + reserved triggers banked on send ch 2. This is the reusable "what full
  control looks like" reference, consistent with the committed
  [`captureprobe.aumproj`](captureprobe.aumproj).
- **Dense, private (not committed)** — a real FabFilter-heavy band session
  instrumented with `preserve_existing:true` **and `add_probes:true`**
  (`<id>_golden`, staged for iPad download only). On the measured corpus this
  appends the brain (→ MIDI Control, merged into the band's matrix) and a tap on
  the chosen instrument channel, preserves the existing hand mappings, banks
  ~1.3k targets across ~11 channels (CC then Note), introduces **zero** new
  collisions, and overflows only a handful of convention slots already occupied
  by hand mappings — the expected behaviour for an exhaustive instrument on a
  huge rig. Loading it connects the rig automatically (Bonjour), so the agent can
  drive and hear it with nothing added on the iPad.

## See also

- [aum-control-surface.md](aum-control-surface.md) — the measured surface and the
  decoded `midiCtrlState` schema this convention writes into.
- [aum-control-implementation-plan.md](aum-control-implementation-plan.md) — where
  this fits in the two-repo plan (the multi-node collision is resolved here).
