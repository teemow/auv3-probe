# AUM control surface — what the brain can read & change

A **measured** spec of the API available to an AUv3 hosted inside
[AUM](https://kymatica.com/aum) — specifically the `ProbeMidiBrain` (`aumi`)
node, the rig's "brain". It answers the four questions from the
[analysis plan](design.md):

1. What can the brain *read* about the AUM session, MIDI routing, transport, and
   the other audio units?
2. What can it *change* in AUM?
3. Is MIDI-out the only control lever, or are there other paths (CoreMIDI,
   `AVAudioSession`, URL schemes, OSC)?
4. Do we always need a session with the brain wired into AUM's MIDI Control?

Everything below was **measured**, not assumed. The AUv3 host API is deliberately
narrow, so the only way to settle this was to instrument the running appex and
read it back while AUM hosts it.

> **The bigger picture.** The brain can reach almost the entire AUM surface — but
> only what a session has mapped. So the brain's power as an AUM controller
> reduces to how well we **understand AUM sessions** and whether every session
> carries a **standard MIDI-control mapping** (so the brain can change scenes).
> That vision — and what is still missing — lives in the orchestrator repo:
> [mcp-midi-controller / aum-brain-control.md](https://github.com/teemow/mcp-midi-controller/blob/main/docs/aum-brain-control.md).
> This file is the measured evidence underneath it.

> Public-repo rule: this file carries no installation-specific data (daemon
> hostnames/IPs, device UDIDs, rig inventory). Measured values are kept generic.

## Apparatus

The probe pairs an instrumented appex with the
[mcp-midi-controller](https://github.com/teemow/mcp-midi-controller) daemon so
one agent can drive AUM end-to-end:

- **Hands** — the daemon pushes MIDI through the brain's LAN channel
  (`send_midi` / `play_notes` / `set_transport`). The brain emits it via
  `midiOutputEventBlock` → into AUM.
- **Eyes** — the brain snapshots every host-reachable surface
  ([`HostDiagnostics`](../Sources/ProbeKit/HostIntrospection.swift)) and streams
  the full envelope to the daemon over `ws://host/diagnostics` (~1 Hz + on
  route/interruption changes), read with the `get_host_diagnostics` MCP tool.
  `os_log` (subsystem `com.teemow.auv3probe`, read on Linux via `idevicesyslog`)
  remains as the offline fallback sink when no socket is connected. Inbound MIDI
  is captured into a lock-free ring
  ([`ObservedMidiRing`](../Sources/ProbeKit/ObservedMidiRing.swift)).
- **Ears** — `ProbeAudioTap` (`aufx`) streams PCM + analysis from an AUM channel
  (`get_audio_tap`), so a write's audible effect is measured as RMS/dBFS.

The verification session wires the brain (slot7) on a MIDI strip, and an audio
channel: `Ravenscroft275` (piano) → Pro-Q4 → Pro-C2 → Pro-L2 → `ProbeAudioTap`.
The brain is routed to AUM's `BuiltIn: MIDI Control` so its MIDI can drive the
mixer/transport.

## Read surface

### Sanctioned host blocks (live & exact)

The two readable host blocks update in real time and match AUM exactly:

| Block | Field | Status |
|---|---|---|
| `transportState` | `moving`, `recording`, `cycling`, `samplePosition` | **live & exact** |
| `transportState` | `cycleStartBeat` / `cycleEndBeat` | live (0 when not cycling) |
| `musicalContext` | `tempo`, `timeSignatureNumerator/Denominator`, `currentBeatPosition` | **live & exact** |
| `musicalContext` | `currentMeasureDownbeatPosition` | **always 0** — AUM never fills it |
| `musicalContext` | `sampleOffsetToNextBeat` | **always 0** — AUM never fills it |

So the brain has trustworthy transport + tempo + beat, but **cannot** rely on
downbeat/next-beat sample offsets for sample-accurate scheduling — AUM leaves
them zero.

### `AVAudioSession` (read-only, available)

The appex can read `AVAudioSession.sharedInstance()`: sample rate (48 kHz),
IO buffer duration (~5.3 ms), in/out port names (built-in mic / speaker),
category/mode, and `isOtherAudioPlaying`. Useful as environment context; not a
control lever.

### CoreMIDI enumeration — no session graph

From inside the appex, CoreMIDI sees only **device/app-level virtual ports**, not
AUM's internal graph:

- sources/destinations resolve to exactly `AUM` and `Netzwerk Session 1`
  (network MIDI). No per-node endpoints, no other plugin instances, no mixer.

There is **no AUv3 API** to enumerate other loaded nodes, read AUM's MIDI matrix,
or read the session graph — confirmed. Structured session knowledge still comes
only from parsing the `.aumproj` off-device (job 2), not from live introspection.

### Inbound MIDI routing into the node

With nothing wired to the brain's MIDI **input**, the observed-MIDI ring stayed
`total=0` throughout transport rolls and tempo changes:

- **AUM routes no MIDI clock / start / stop / continue into the node.** Transport
  and tempo arrive **only** via the host blocks above, never as MIDI realtime
  messages. A node that wants clock cannot get it from AUM this way.
- What a node receives on its input is exactly (and only) what the session's MIDI
  matrix routes to it.

## Write surface

Two independent write paths exist, and they do different things.

### Path A — via AUM MIDI Control (the mixer/transport dispatcher)

With the brain routed to `BuiltIn: MIDI Control`, a CC the brain emits hits
whatever AUM function is mapped to it. This is the broad lever. Confirmed
closed-loop in the verification session (`test_mcp_scene`):

| Target | Mapping | Measured result |
|---|---|---|
| Transport — Start | CC62, ch16 | `transportState.moving` → `true`, sample position advances |
| Transport — Stop/Rewind | CC61, ch16 | `moving` → `false` |
| Transport — Record | CC63, ch16 | toggles `recording` |
| **Tempo** | CC21, ch2 | **linear 20–500 BPM**: CC 0 → 20, 64 → 262, 127 → 500 BPM |
| Channel **Mute** | CC20, ch2 | 127 mutes (≈ −33.9 → −56.8 dBFS at the tap), 0 unmutes |
| Channel **Volume** | CC7, ch1 | fader; 0 → full silence, up → audio (tap is post-fader) |
| **Per-node plugin param** (Pro-L2 *Output Level*, −30…0 dB) | CC22, ch2 | 127 → full (≈ −42 dBFS), 0 → −30 dB (≈ −92 dBFS) |

The plugin-parameter case is the important one: a routed CC can drive an
**arbitrary parameter of an arbitrary node** in the chain, not just mixer
globals. Combined with AUM's own help
([MIDI Control](https://kymatica.com/aum/help)), the mappable target set is:
channel volume/mute/solo/rec, **any node parameter**, node bypass, transport,
**Tempo + Tempo Presets**, plugin **Preset Load**, and **Session Load**.

> **Correction to an earlier assumption:** AUM **can** do **Session Load** and
> **Tempo** via MIDI — earlier notes wrongly said it could not. Tempo is now
> measured above. Session-Load and some preset actions are stored **globally**
> (not in the `.aumproj`), which is why they don't appear in a parsed session
> map — but the brain → MIDI Control dispatcher can still trigger them. So a
> brain wired to MIDI Control can drive essentially the entire AUM surface,
> including loading other sessions and setting tempo.

### Path B — direct to a synth (no MIDI Control needed)

When the brain is wired straight to a synth node, `play_notes` reaches the synth
and produces sound **regardless of any MIDI-Control mappings**. Notes/CC aimed at
an instrument do not need the MIDI-Control dispatcher at all.

### MIDI-Control-vs-direct matrix

| You want to… | MIDI Control wired? | How |
|---|---|---|
| Play / excite a synth node | not required | route brain → synth; send notes/CC |
| Start/stop/record, set tempo | **required** | map transport/tempo targets |
| Mute/solo/volume a mixer channel | **required** | map channel controls |
| Change any node's parameter | **required** | map that node param |
| Load another session / a plugin preset | **required** (global action) | map Session/Preset Load |

Answer to Q4: you only need MIDI Control wired for **AUM-side** control (mixer,
transport, tempo, params, session/preset). For just **playing notes into a
synth**, you don't.

## Channel encoding gotcha (`.aumproj`)

AUM's MIDI-Control mapping stores the channel **0-indexed**: the parsed map's
`ch=N` means **MIDI channel N+1**. Verified against known-good mappings —
chan1 Volume stored `ch=0` drives on MIDI ch1; Start stored `ch=15` drives on
MIDI ch16. The scene's three added mappings stored `ch=1` ⇒ they must be driven
on **MIDI channel 2**. Tooling that synthesizes mappings or sends to them must
apply this `+1`, or the CC silently hits nothing.

## Decoded `.aumproj` MIDI-Control format (`midiCtrlState`)

The on-disk format was reverse-engineered from a purpose-built **probe session**:
a session that hand-maps one of every target/message-type/flag, ferried to the
daemon and decoded from the NSKeyedArchiver `.aumproj` (`get_aum_session` for the
flat view; raw `$objects` walk for the attributes the flat view drops). The result
is the exact schema below — enough to *author* the full surface, not just read it.

### Per-mapping schema

Every mapped target stores one spec dict:

```jsonc
{
  "channel": 0,            // MIDI channel, 0-indexed (0 = ch1); OMNI sentinel unconfirmed
  "min": 0.0, "max": 1.0,  // value Range, normalised 0..1
  "autoToggle": false,     // the "Cycle" flag
  "specState": {
    "enabled": true,       // false = channel set to OFF (mapping inactive)
    "type": 0,             // message type (table below)
    "data1": 7             // number (CC/note/program); subtype for PBEND/CHPRS
  }
}
```

### Message-type codes (`specState.type`) — confirmed

| AUM type | `type` | `data1` |
|---|---|---|
| CC | 0 | CC number |
| NOTE | 1 | note number |
| PC | 2 | program number |
| PBEND | 3 | **0** |
| CHPRS | 3 | **1** |

PBEND and CHPRS share `type=3` and are disambiguated by `data1` (0 vs 1) — not by
the type byte. (`TypeProgramChange = 2` is now confirmed, no longer a guess.)

### Flag / attribute encodings

| AUM UI control | On-disk |
|---|---|
| **Cycle** | `autoToggle: true` |
| **Invert** (Toggle) | `min`/`max` swapped (e.g. `min=1.0, max=0.0`) |
| **Range** (Value/Indexed) | normalised `min`/`max` (e.g. 35 % → `min≈0.3529`) |
| **Channel OFF** | `specState.enabled: false` |
| **Channel 1..16** | `channel` = N−1 (0-indexed) |

### Target key strings (the collection paths)

These are the exact identifiers, ready to author:

- **Channel** — audio strips: `Channels/chan<N>/Channel controls/{Volume,Mute,Solo,Rec enable,ScrollToChannel}`.
  MIDI strips carry the **same** `Channel controls` collection but populated with
  **only `ScrollToChannel`** (no Volume/Mute/Solo/Rec) — confirmed on the brain's
  MIDI strip (`chan1`).
- **Node param** — `Channels/chan<N>/slot<S>/<paramName>` (e.g. `Master Vol`; an
  unnamed AU param appears as its index, e.g. `slot0/0`)
- **Node actions** — `…/slot<S>/_AUMNode:Bypass`, `_AUMNode:FrontPlugin`
  (Show & Front), `_AUMNode:TogglePlugin` (Show / Hide),
  `_AUMNode:PresetLoadCtrl/<idx>:<presetNumber>:<name>` (dynamic, one per added
  preset). The middle field is the **AU preset's own number** (not the MIDI
  program); the program that fires it is the leaf's `specState.data1`. Proof from
  `captureprobe_2`: `…/1:1:Damage_Bass` (presetNumber `1`) fires on `PC data1=2`.
- **Transport** — `Transport/{Toggle Play,Start Play,Stop/Rewind,Rewind,Tap Tempo,Toggle Record,Previous bar,Next bar,Metronome on/off,Tempo,Rewind when stopped}`
  and `Transport/Tempo Presets/<idx>:<bpm>` (dynamic)
- **System** — `System/_AUM:ShowSelf` (Switch to AUM), `System/_AUM:HideAllPlugins`,
  `System/_AUM:UnSoloAll`

Node bypass is keyed per slot, so **any** node's bypass is mappable — including the
hardware-output node (`slot<S>/_AUMNode:Bypass` on the `HWOutputDescription` slot),
i.e. a MIDI "kill to speakers".

### Two structural facts

- **AUM auto-creates a disabled control for every writable parameter.** A freshly
  hosted plugin contributes one `enabled:false, type=0, data1=0` placeholder per
  writable param, dormant until mapped. This is the on-disk evidence for the
  CC-budget concern: a single channel has only 128 CCs. Two answers exist — a
  **preset-first + curated CC** device type per plugin, and, when exhaustive
  control is wanted, the **golden banking allocator** that spreads every target
  across MIDI channels (CC then Note) while keeping the mixer/transport
  convention CCs in place. See [golden-session.md](golden-session.md).
- **Session Load is *not* in the file.** A mapped Session Load action does not
  appear in the `.aumproj` — confirming AUM persists Session Load actions
  **globally**. Cross-session load therefore needs a daemon-owned PC→session
  registry, not file authoring.
- **`slot<S>` is a raw storage index, *not* signal-chain / visible-effect order.**
  AUM appends nodes to the channel's node array in creation order: the source is
  `slot0`, the auto-created hardware-output node is `slot1`, and an effect inserted
  as the *first visible effect slot* lands at `slot2` (after the output node in the
  index). Confirmed in `captureprobe`: `iSEM` = `slot0`, `HWOutputDescription` =
  `slot1`, `ProbeAudioTap` = `slot2` (its bypass is `slot2/_AUMNode:Bypass`, CC 51).
  So **resolve a node by its component identity / class, never by assuming
  `slot0` = first effect.** (The midiCtrlState `slot<S>` keys use this same raw
  index, so they align 1:1 with the decoded node list.)

### Still open

- **OMNI channel sentinel** — not exercised (all probe mappings used ch1).
- **Globally-stored actions** (Session Load, possibly some preset/system actions)
  — live outside `.aumproj`; need a separate capture of AUM's global store.

### Captured probe session (artifacts in this repo)

The captures themselves are committed for reference:

- [`captureprobe.aumproj`](captureprobe.aumproj) — the raw AUM session (binary
  NSKeyedArchiver plist) with one hand-mapped target of every kind, plus the brain
  on its own MIDI strip (`chan1`, `ScrollToChannel` = CC 50) and the audio tap as a
  channel effect (`slot2`, bypass = CC 51).
- [`captureprobe-midi-control.json`](captureprobe-midi-control.json) — the decoded
  26 assigned mappings (target path, type, data1, channel, min/max, autoToggle),
  i.e. a reviewable view of the binary above.
- [`captureprobe_2.aumproj`](captureprobe_2.aumproj) /
  [`captureprobe_2-midi-control.json`](captureprobe_2-midi-control.json) — a second
  capture (Continua) with **two** preset-load actions
  (`…/0:1:Abandoned_Themepark` → PC 1, `…/1:1:Damage_Bass` → PC 2): both store
  presetNumber `1` yet fire on different programs, proving the middle key field is
  the AU preset number, not the MIDI program.

### Live closed-loop verification (2026-06-05)

The PC type code was confirmed not just on disk but **audibly in a live AUM host**.
With the brain + tap loaded and routed (brain → AUM `MIDI Control`; brain → iSEM,
notes filtered to ch2), driven via the daemon's `send_midi` / `get_audio_tap`:

- **Routing** — `noteOn 60, ch2` → tap heard a clear tone (C5, 522 Hz, −23 dBFS,
  onset registered): hands → brain → AUM route → iSEM → tap is closed.
- **PC Preset Load** — `pc program=1, ch1` (the mapped
  `_AUMNode:PresetLoadCtrl/0:1:GVS_xtranasty_BA`) measurably changed the *same*
  note's timbre at the tap: centroid 2788 → 1487 Hz, HNR 22.1 → 0.0 dB (tonal →
  noisy), level −23.1 → −19.6 dBFS, onsets 1 → 5. AUM's MIDI Control dispatcher
  loaded the mapped preset; the audible result confirms `PC=2` end-to-end and the
  `+1` channel rule (action at stored `ch=0` responded on MIDI ch1).
- **PC Session Load (cross-session)** — `pc program=10, ch1` triggered AUM's
  **global Session Load** action and swapped the whole `.aumproj` (`captureprobe`
  → `captureprobe_2`). Two independent signals confirmed it: the ProbeAudioTap
  re-instantiated on a **new connection port**, and note 60 changed from C5
  (iSEM, octave-shifted) to **C4** (Continua) — a different synth. Preset switch
  inside the loaded session (`pc 1`/`pc 2`, ch1) then toggled Continua tonal ↔
  inharmonic, reversibly. This validates the **daemon-owned PC→session registry**
  model for the globally-stored Session Load actions (which never appear in the
  file).
- **Brain survives a session reload** — after the `PC 10` swap, the next
  `send_midi`/`noteOn` reached the *new* session's brain with no re-wiring: the
  always-on, Bonjour-discovered control channel **auto-reconnects across a full
  session change**, so cross-session scene changes are laptop-free.

## Backdoors

| Path | Result |
|---|---|
| `AVAudioSession` read | **available** (read-only environment, see above) |
| CoreMIDI **enumerate** AUM/network ports | **available** (device-level ports only; no graph) |
| CoreMIDI **direct send** to the `AUM` destination (outside the AU graph) | **untested** — `AUM` is a visible destination; a `#if DEBUG` client exists ([`MidiBackdoor`](../Sources/ProbeKit/MidiBackdoor.swift)) but the send has not yet been exercised |
| URL scheme / OSC into AUM | not available to a sandboxed appex |

## Definitive answer — "is MIDI the only way?"

For **driving AUM**, yes in practice: MIDI (out of the node, into AUM MIDI
Control) is the sanctioned and sufficient control lever, and it reaches the whole
surface — transport, tempo, mixer, **any node parameter**, and global
session/preset load. The host API gives **read** of transport/tempo/beat and the
audio session, but **no** read of the session graph and **no** non-MIDI write
path. The one unexplored alternative is a direct CoreMIDI send to AUM's virtual
destination (backdoor, untested).

## Open items

- **Backdoor send**: exercise the DEBUG CoreMIDI client → CC to the `AUM`
  destination; confirm whether AUM acts on it (one on-device tap to trigger).
- **Inbound routing**: drive the brain's MIDI **input** from hardware (footswitch)
  and confirm channel mapping / passthrough via the observed-MIDI ring.
- **Live Session Load / Preset Load**: set up the global action in AUM, trigger it
  from the brain, confirm.

## References

- The vision this measures (sessions + standard mapping → brain scene control):
  [mcp-midi-controller / aum-brain-control.md](https://github.com/teemow/mcp-midi-controller/blob/main/docs/aum-brain-control.md).
- Exhaustive, collision-free mapping of the whole surface: [golden-session.md](golden-session.md).
- Analysis design & plan: [`docs/design.md`](design.md),
  [`docs/auv3-extension.md`](auv3-extension.md).
- Instrumentation: [`Sources/ProbeKit/HostIntrospection.swift`](../Sources/ProbeKit/HostIntrospection.swift),
  [`Sources/ProbeKit/ObservedMidiRing.swift`](../Sources/ProbeKit/ObservedMidiRing.swift),
  [`Sources/ProbeKit/MidiBackdoor.swift`](../Sources/ProbeKit/MidiBackdoor.swift).
- AUM MIDI Control reference: <https://kymatica.com/aum/help>.
