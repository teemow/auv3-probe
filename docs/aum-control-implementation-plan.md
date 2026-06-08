# AUM brain-control — two-repo implementation plan

The follow-on to [aum-control-surface.md](aum-control-surface.md): turning the
*measured* control surface into a reliable, agent-driven (and footswitch-driven)
**scene-change rig**. Spans this repo (`auv3-probe`, the iPad node) and
[mcp-midi-controller](https://github.com/teemow/mcp-midi-controller) (the
orchestrator). It expands the four next-steps named in that repo's
`docs/aum-brain-control.md` into a concrete, sequenced task list.

> Public-repo rule: no installation-specific data here. Capability counts come
> from the measured probe corpus (a device-type library), not from any one rig.

## Thesis

The measurement settled it: **the brain can change almost everything in AUM over
MIDI — but only what the loaded session has *mapped*.** AUM ships no factory CC
map; a function responds to a message only if the `.aumproj` wires that message to
it. So the brain's power is bounded by two things, and *only* these two:

1. **How well we understand AUM sessions** — the daemon's model of `.aumproj`
   (channels, nodes, params, mappings, global actions) must be deep and exact.
2. **A standard MIDI-control mapping** baked into every session — a canonical,
   session-independent vocabulary the brain emits to drive the mixer, transport,
   tempo, node params, presets, and **scene/session changes**.

Get those two right and the brain becomes a near-complete AUM remote that an AI
agent (or a pedalboard) can drive deterministically. This document is the plan to
get there. Both pillars are early — the model has known holes and the standard
mapping is not yet authored by default.

## Current state (grounded)

What already exists, so the plan only builds the delta:

- **Measured surface** (this repo): transport/tempo/mixer/any-node-param all
  driveable via AUM `BuiltIn: MIDI Control`; tempo is linear 20–500 BPM; channel
  encoding is **0-indexed** in the file (`ch=N` ⇒ MIDI ch N+1); AUM routes no MIDI
  clock into a node; no live session-graph read. See
  [aum-control-surface.md](aum-control-surface.md).
- **Session model** (`mcp-midi-controller/internal/aum`): strong typed read/edit
  over the NSKeyedArchiver `.aumproj` across schema v8/10/13 —
  `Session`/`Channel`/`Node`/`Mapping`/`Spec`, `BuildSession`, `SetMapping`,
  `SetMIDIRoutes`, `CheckMixerConvention`. A `Convention` (the server-owned CC map)
  exists and works for mixer CCs.
- **Brain "hands" + tap "ears"**: `ProbeMidiBrain` dials `ws://host/midi-control`
  (daemon → brain command frames); `ProbeAudioTap` streams PCM/analysis. The brain
  stores a `BrainProgram` (song sections + footswitch map + output encoding) in
  AUM per-node `fullState`.
- **Scene tooling**: daemon-side `scene` = a desired-state snapshot of bound
  logical devices; `recall_scene` replays it over **hardware transports**
  (BLE-MIDI direct to AUM), **not** through the brain. `author_loop_session` wires
  the brain→synth→tap loop but does **not** bake in the standard convention.
- **First-class Device direction**: PDR
  `2026-06-04-pdr-mcp-midi-first-class-device-model` — AUM and each AUv3 node
  become `Device`s auto-derived from the live session.

## Implementation status

What has landed in code (build + tests green on the daemon side), and what is
still gated on a live AUM capture or on-device run. File references are to the
two repos.

**Done (mcp-midi-controller, `go build`/`go test`/`go vet` clean):**

- **Canonical transport block + authoring** (Pillar 2.1, partial). `internal/aum`
  gains `conventionTransportCC` and `applyConvention` now wires the global
  Transport block (CC 20 + 102–105 + 108 → Toggle Play / Start Play /
  Stop-Rewind / Rewind / Toggle Record / Tap Tempo) on the convention channel,
  alongside the existing mixer + node-param CCs.
- **Auto-bake by default** (Pillar 2.2). `author_loop_session` always bakes the
  standard convention (channel 1); `author_aum_session` bakes it by default,
  with `bare:true` to opt out and an explicit `convention` object to customize.
- **Full-surface diff** (Pillar 2.4). `Session.CheckConvention` extends the
  mixer check with the transport block; `diff_aum_session` now reports
  mixer+transport coverage.
- **Scene recall via the brain** (Pillar 3.1). `engine.RecallSceneVia` takes an
  optional sink; `recall_scene` grows `via=auto|brain|hardware` — `auto` prefers
  the brain when one is connected (the brain re-emits inside AUM, laptop-free)
  and falls back to the device transports otherwise. Raw MIDI → brain command
  translation is `brainCommandFromMIDI` (SysEx/PBEND/CHPRS skipped on the brain
  path; USB blobs are hardware-only).
- **Message-type naming** (Pillar 1, partial). `spec.go` names the candidate
  `TypePitchBend`/`TypeChannelPressure` codes (clearly UNCONFIRMED, not emitted)
  and adds `SpecTypeName` so inspection/diff output never presents a guessed
  code as fact.

**Confirmed by capture (probe session, 2026-06-05) — ready to pin:**

A purpose-built probe session (one of every target/type/flag) was authored in
AUM, uploaded, and decoded from the raw `.aumproj` (`midiCtrlState`). The capture
artifacts are committed: [`captureprobe.aumproj`](captureprobe.aumproj) (raw) and
[`captureprobe-midi-control.json`](captureprobe-midi-control.json) (decoded 25
mappings). See [aum-control-surface.md](aum-control-surface.md) → *Decoded
`.aumproj` MIDI-Control format* for the full schema and the **live closed-loop
verification**. Net results:

- **Type codes confirmed**: `CC=0`, `NOTE=1`, `PC=2` (the old guess is correct),
  and `PBEND`/`CHPRS` both `type=3`, disambiguated by `data1` (PBEND `data1=0`,
  CHPRS `data1=1`). PC-based preset/session-load *authoring* is now unblocked.
- **Transport key strings confirmed**: `Transport/{Previous bar, Next bar,
  Metronome on/off, Tempo, Tempo Presets/<idx>:<bpm>}` (plus the already-known
  Toggle Play / Start / Stop-Rewind / Rewind / Toggle Record / Tap Tempo).
- **Node-action key strings confirmed**: `_AUMNode:Bypass` (per slot — incl. the
  HW-output node), `_AUMNode:FrontPlugin` (Show & Front),
  `_AUMNode:TogglePlugin` (Show / Hide),
  `_AUMNode:PresetLoadCtrl/<idx>:<presetNumber>:<name>` (middle field is the AU
  preset's own number, **not** the MIDI program; the firing program is `data1`).
- **`slot<S>` = raw storage index, not visible-effect order** (source `slot0`,
  HW-output `slot1`, first inserted effect `slot2`); resolve nodes by component
  identity, never assume `slot0` = first effect.
- **System + channel key strings confirmed**: `System/_AUM:{ShowSelf,
  HideAllPlugins,UnSoloAll}`; `Channels/chan<N>/Channel controls/ScrollToChannel`
  (present on **MIDI** strips too, as the only Channel control they expose).
- **Flag/attribute encoding confirmed**: Cycle = `autoToggle`, Invert = swapped
  `min`/`max`, Range = normalised `min`/`max`, OFF = `specState.enabled=false`,
  channel 0-indexed.
- **Negative results confirmed**: Session Load is **absent** from the file (global
  storage) → needs the daemon-owned PC→session registry, not file authoring. AUM
  also auto-creates a disabled control per writable param (CC-budget evidence).

**Done (mcp-midi-controller) — golden full-control banking:**

- **Multi-node CC collision RESOLVED.** The single-channel `Convention`
  (one CC per node param, restarting per node on one channel) collided on
  multi-node sessions: two nodes' params shared a CC, so one message drove
  several. `internal/aum/instrument.go` adds a **banking allocator**
  (`Session.Instrument`) that assigns every mappable target collision-free,
  spreading across MIDI channels (CC 0..127 then Note 0..127 per channel) in
  priority order — global+mixer on the convention channel, then node reserved
  triggers, instrument (`aumu`) params, effect (`aufx`/`aumf`) params from ch 2
  up. Overflow past ch 16 is reported, not fatal; `preserve_existing` makes
  re-instrumenting safe and idempotent. The mixer/transport convention CCs stay
  on the `device.Convention*` band so the session-derived `MixerDeviceType` still
  resolves. Exposed as the `instrument_aum_session` MCP tool, `full_control:true`
  on `author_aum_session`, and `author_probe_session`. Full design:
  [golden-session.md](golden-session.md).

**Done (auv3-probe):**

- **Committed golden example** — [`docs/examples/golden-example.aumproj`](examples/golden-example.aumproj)
  + decoded [`golden-example-midi-control.json`](examples/golden-example-midi-control.json):
  a clean brain + iSEM + delay + tap + master rig, instrumented full-control (51
  mappings, 2 channels, no overflow), as the reusable full-control reference.

- **Standard brain scene-change encoding** (Pillar 3.2). `SongStructure.swift`
  adds `BrainControlConvention` (the explicit channel allocation shared with the
  daemon — channel 1, Session-Load = Program Change, transport CCs for
  reference) and `BrainProgram.standard(...)`; `BrainProgram` defaults are now
  pinned to the convention so transport/footswitch scene changes match exactly
  what the daemon authors/sends. *Not compiled here* (no Swift toolchain on
  Linux; the AU targets need Apple frameworks) — review-only.

**Resolved by the 2026-06-05 capture (was gated, now confirmed — pin in code):**

- **PC / Pitch-Bend / Channel-Pressure type codes** — confirmed (`PC=2`,
  `PBEND=3/data1=0`, `CHPRS=3/data1=1`). Pin in `spec.go` and enable PC encode.
- **Extended transport targets** (Previous/Next bar, Tempo, Metronome, Tempo
  Presets) — key strings confirmed; safe to add to
  `buildTransport`/`conventionTransportCC`.
- **Node bypass / Show-Front / Show-Hide / Preset Load / System actions /
  Scroll-to-channel** — key strings confirmed; can be modeled in the convention.
- **Cycle / Invert / Range attributes** — encoding confirmed (`autoToggle`,
  swapped `min`/`max`, normalised `min`/`max`); extend the `midiCtrlState`
  parser + `SessionMap` to surface and author them (the flat `get_aum_session`
  view currently drops them).

**Still gated:**

- **Pan / sends** — defined in the convention but require a Stereo Balance / Bus
  Send node (and that node's component identity) to physically exist; not
  auto-authored.
- **Global Session Load** — *cross-session load now confirmed working*
  (2026-06-05): `pc 10, ch1` through the brain swapped `captureprobe` →
  `captureprobe_2` (tap re-instantiated on a new port; note 60 went C5/iSEM →
  C4/Continua), and the brain auto-reconnected across the swap. The
  daemon-owned PC→session registry model is validated. Still to formalize:
  authoring/recording that registry daemon-side (the actions live outside
  `.aumproj`). `.aum_aupreset` (user-preset container) remains unmodeled.
- **OMNI channel sentinel** — the on-disk value for OMNI is unconfirmed (the
  probe used ch1 only); capture one OMNI mapping to pin it.
- **First-class Device auto-derivation** (the PDR refactor) — larger, deferred.
- **End-to-end verification** — *loops confirmed* (2026-06-05): (a) a PC →
  `MIDI Control` loaded a mapped iSEM **preset**, measured audibly at the tap
  (centroid 2788→1487 Hz, HNR 22→0 dB); (b) a PC triggered a **cross-session
  load** (`captureprobe` → `captureprobe_2`), with the brain auto-reconnecting
  across the swap. Remaining targets (transport, mixer CCs, daemon `recall_scene`
  → brain) still confirmable only on the live rig.

## Pillar 1 — Deep session understanding (mcp-midi-controller)

Close the model gaps so the daemon knows *exactly* what a session exposes and can
author the full surface. All in `internal/aum` unless noted.

| Gap | Task | Notes / blocker |
|---|---|---|
| **PC / Pitch-Bend / Channel-Pressure `type` codes** | **CONFIRMED (2026-06-05 capture)**: `PC=2`, `PBEND=3/data1=0`, `CHPRS=3/data1=1`. Pin in `spec.go`; add PC encode support | **Unblocked.** Decoded from a probe `.aumproj`. Enables preset/session-load authoring. |
| **Cycle / Invert / Range attributes dropped by the parser** | Extend the `midiCtrlState` parse + `SessionMap` to read/author `autoToggle` (Cycle), swapped `min`/`max` (Invert), and normalised `min`/`max` (Range) | **Unblocked.** Encoding confirmed; `get_aum_session`'s flat view currently omits these. |
| **Global Session Load actions invisible** (AUM stores them globally, not in `.aumproj`) | Formalize the daemon-owned registry (PC# → session id) and record it daemon-side since the file can't | **Confirmed file-invisible AND confirmed working** (2026-06-05): `pc 10, ch1` loaded another session live (tap re-instantiated; synth identity changed). The PC→session registry model works; remaining work is authoring/persisting it daemon-side. |
| **`.aum_aupreset` (user preset) format unknown** | Reverse-engineer the container; add read + stage so user presets are recallable by name | Lower priority; factory presets via PC already work. |
| **Tempo Presets + full transport/system catalogue not in `BuildSession`** | Extend `buildTransport`/the target catalogue using the confirmed key strings: `Transport/{Previous bar,Next bar,Metronome on/off,Tempo,Tempo Presets/<idx>:<bpm>}`, `System/_AUM:{ShowSelf,HideAllPlugins,UnSoloAll}`, node `_AUMNode:{Bypass,FrontPlugin,TogglePlugin,PresetLoadCtrl/<idx>:<presetNumber>:<name>}`, `ScrollToChannel` | **Key strings now confirmed** (2026-06-05 capture). Straightforward to enumerate. |
| **Pan target needs a Stereo Balance node to physically exist** | Have the authoring path auto-insert a Stereo Balance node when a pan CC is requested | Or drop pan from the default convention. |
| **AUM mixer device divorced from live session** (per PDR) | Auto-derive the AUM mixer `Device` + one `Device` per AUv3 node from the loaded session's `midiMatrixState` (channels, not fixed `ch1..ch8`), `Origin = aum-session` | Lands with the `Binding`→`Device` refactor. |

Output of this pillar: the daemon can read **and author** every mappable AUM
target, with correct channel encoding, validated by re-decode.

## Pillar 2 — A standard brain-control mapping ("the brain control surface")

A canonical CC/PC map the brain always speaks, baked into every authored session,
and exportable as a standalone `.aum_midimap` for import into existing real
sessions. Extends the existing `Convention`.

1. **Define the canonical map** (extend `aum.Convention` / `aum.yaml`), covering
   the whole surface on a **reserved brain channel scheme**:
   - **Mixer**, per channel N: mute / level / pan / solo / rec / sends (the
     existing `18+3N`, `44+N`, … bands).
   - **Transport + tempo + metronome** (the CC 102–113 block) and **Tempo
     Presets**.
   - **Per-node params**: preset-first (Program Change, with **Bank Select** once
     presets > 128) as primary; a **bounded, curated CC subset** for fine-tuning
     (per the device-model PDR — naive "one CC per param" overflows; 23 plugins
     exceed the 128-CC budget).
   - **Node bypass**.
   - **Scene / Session Load**: a dedicated PC range (in-session preset/scene) and a
     daemon-registered PC→session map for cross-session loads.
   - Reserve and **document the channel allocation explicitly** (which MIDI
     channels carry mixer vs transport vs scene), and bake the **0-index `+1`**
     correctly so authored CCs land where intended (this bit us once).
2. **Auto-bake by default**: make `author_loop_session` (and `author_aum_session`
   when no explicit convention is given) apply the standard convention, so a
   freshly authored session is brain-controllable with zero hand-wiring.
3. **Emit a baseline `.aum_midimap`**: generate the standard mapping as a
   standalone file (`export_aum_midimap` path) so it can be imported into
   pre-existing real sessions, not only daemon-authored ones.
4. **`diff_aum_session` against the standard**: extend `CheckMixerConvention` to
   report coverage of the *full* standard map (not just mixer CCs), so any session
   can be checked/fixed for brain-readiness.

Output: any session — authored or hand-made — can be made to speak the brain's
standard vocabulary, verifiably.

## Pillar 3 — The payoff: scene changes via the brain

This is the powerful part the framing calls out. Two kinds of "scene change":

- **In-session scene** (mixer/param state within one loaded `.aumproj`): express a
  daemon `scene` as the standard CCs/PCs from Pillar 2 and have the **brain** emit
  them, instead of (or in addition to) BLE-MIDI direct.
- **Cross-session scene** (load a different `.aumproj`): a single **Session Load
  PC** the brain emits; depends on Pillar 1's global-action handling.

Tasks:

1. **Wire `recall_scene` to the brain.** Add a brain-first path: compile the scene
   to standard MIDI (reuse `CompileFootswitchScene`'s PC-before-CC + settle logic)
   and push it through `internal/midicontrol` `hub.Send` to the brain, falling back
   to BLE-MIDI when no brain is connected (mirrors the `midi_tools` transport
   override already in `play_notes`/`send_midi`). The brain re-emits in-host → AUM
   applies it. Laptop-free once authored.
2. **Standardize the brain's own scene-change encoding.** The brain already holds a
   `BrainProgram` (song sections pinned to beats + footswitch map + output
   encoding). Pin its scene-change output to the Pillar-2 canonical map so
   transport-position and footswitch triggers produce the *same* standard messages
   the daemon would. (`auv3-probe`: `Sources/ProbeKit/SongStructure.swift` +
   `Sources/ProbeMidiBrain/BrainEngine.swift`.)
3. **Verify with the loop.** Use the rig's hands+ears: trigger a scene (agent
   `recall_scene` → brain, or footswitch → brain, or transport boundary → brain),
   then confirm the audible result via `get_audio_tap` (level/param change) and the
   brain's `transport`/`musical` introspection (tempo/transport). This is the
   `author → load → play → hear → tweak` agent loop end-to-end.

## auv3-probe (this repo) side work

Mostly Pillar 3 + optional live introspection:

- **Standard scene-change encoding** in `BrainProgram`/`BrainEngine` output (Pillar
  3.2) — the brain must speak exactly the Pillar-2 map.
- **Permanent host-diagnostics channel — DONE (no longer deferred).** The
  analysis originally used `os_log` and this was filed as optional/defer; that
  decision is **reversed**. The earlier "limited value beyond transport/tempo"
  judgement underrated the surface: the appex can read far more than transport —
  its own AU identity/capabilities, **MIDI 1.0-vs-2.0 negotiation** and MIDI-CI
  profiles, the full `AVAudioSession` route/channels/latency, the **CoreMIDI
  graph** (which endpoints/devices the sandbox can see), and the runtime
  environment (thermal/power) — none of which the daemon can infer off-device.
  Streaming the whole `HostDiagnostics` envelope from a view-independent
  `ProbeKit` reporter to a daemon ingest is therefore worth it as a permanent
  channel, not a debug crutch. Implemented as a new `ProbeKit` reporter +
  streamer (`HostDiagnosticsReporter` / `DiagnosticsStreamer`) over
  `ws://host/diagnostics`, terminated by `mcp-midi-controller`'s
  `internal/diagnostics` and exposed via the `get_host_diagnostics` MCP tool. See
  the "Diagnostics protocol" wire contract in
  [auv3-extension.md](auv3-extension.md).
- **Known host-API limits to encode in tooling**: `currentMeasureDownbeatPosition`
  and `sampleOffsetToNextBeat` are always 0 (no sample-accurate beat scheduling);
  AUM routes no MIDI clock into the node — the brain schedules off transport
  sample-position + tempo, not incoming clock.

## Sequencing

1. **~~Capture the PC type code~~ — DONE (2026-06-05).** Type codes + full key
   strings + cycle/invert/range encoding all confirmed from a probe `.aumproj`.
   Next: pin in `spec.go` and extend `buildTransport`/the target catalogue +
   `midiCtrlState` parser to cover the now-confirmed targets/attributes.
2. **Canonical map + auto-bake** (Pillar 2.1–2.2) — makes authored sessions
   brain-ready by default; immediate value.
3. **Wire `recall_scene` → brain** (Pillar 3.1) — the first end-to-end agent scene
   change; demo-able with the tap.
4. **Brain scene-change encoding standardization** (Pillar 3.2) — footswitch +
   transport-driven scenes use the same map.
5. **Baseline `.aum_midimap` + full-surface diff** (Pillar 2.3–2.4) — bring
   existing real sessions into the standard.
6. **First-class Device auto-derivation** (Pillar 1, last row; the PDR refactor) —
   larger; lands the uniform device model.
7. **Cross-session Session Load + `.aum_aupreset`** (Pillar 1) — once the
   global-action model is settled.

## Risks / open questions

- **PC type code** — *resolved* (2026-06-05 capture: `PC=2`, `PBEND=3/data1=0`,
  `CHPRS=3/data1=1`). **Global Session Load** — *resolved/working* (2026-06-05:
  `pc 10` loaded another session live); remaining work is authoring/persisting the
  PC→session registry daemon-side, not a measurement.
- **CC budget**: per-param CC does not scale **on one channel** (measured:
  writable-param counts up to 3225; 23 plugins exceed 128/channel). Two
  complementary answers: a **preset-first + curated-CC** device type per plugin
  (the device-model PDR — don't regress to bulk binding on one channel), and the
  **golden banking allocator** ([golden-session.md](golden-session.md)) which,
  when exhaustive control is wanted, banks every target across channels (CC then
  Note) and reports the overflow rather than colliding.
- **No MIDI-in from brain to daemon**: the `/midi-control` channel is one-way, so
  the daemon can't *observe* what the brain emitted; verification is via the audio
  tap (ears) only. A future brain→daemon ack/echo is reserved but unbuilt.
- **Channel encoding**: every authoring/sending path must apply the 0-index `+1`,
  or CCs silently miss.

## Validation

Every milestone is verifiable on the live rig with the instrumentation built for
the analysis: **hands** (`send_midi`/`play_notes`/`set_transport` → brain →
in-host emit), **eyes** (`get_host_diagnostics` — the streamed `HostDiagnostics`
snapshot: transport/musical context, AU/MIDI/audio-session/CoreMIDI/environment;
`os_log` is now just the offline fallback sink), **ears** (`get_audio_tap`
RMS/dBFS + analysis). The scene demo in
[aum-control-surface.md](aum-control-surface.md) is the template: drive a mapping,
read the audible/host-state result, confirm closed-loop.

## References

- Measured surface: [aum-control-surface.md](aum-control-surface.md).
- Extension/runtime design: [auv3-extension.md](auv3-extension.md),
  [design.md](design.md).
- mcp-midi-controller: `docs/aum-brain-control.md` (the vision this expands),
  `docs/research/aum.md` (the convention CC map), `docs/research/aum-session.md`
  (schema + open items), `docs/research/aum-midi-matrix.md`,
  `docs/research/agent-loop.md`; code in `internal/aum`, `internal/midicontrol`,
  `internal/scene`, `internal/engine`, `internal/mcpserver`.
- Decisions: `2026-06-04-pdr-mcp-midi-first-class-device-model`,
  `2026-06-04-adr-mcp-midi-full-fidelity-segment-probes`.
