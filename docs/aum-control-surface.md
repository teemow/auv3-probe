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
  ([`HostIntrospection`](../Sources/ProbeKit/HostIntrospection.swift)) and logs
  one compact line per section over `os_log` (subsystem `com.teemow.auv3probe`),
  read on Linux via `idevicesyslog`. Inbound MIDI is captured into a lock-free
  ring ([`ObservedMidiRing`](../Sources/ProbeKit/ObservedMidiRing.swift)).
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
- Analysis design & plan: [`docs/design.md`](design.md),
  [`docs/auv3-extension.md`](auv3-extension.md).
- Instrumentation: [`Sources/ProbeKit/HostIntrospection.swift`](../Sources/ProbeKit/HostIntrospection.swift),
  [`Sources/ProbeKit/ObservedMidiRing.swift`](../Sources/ProbeKit/ObservedMidiRing.swift),
  [`Sources/ProbeKit/MidiBackdoor.swift`](../Sources/ProbeKit/MidiBackdoor.swift).
- AUM MIDI Control reference: <https://kymatica.com/aum/help>.
