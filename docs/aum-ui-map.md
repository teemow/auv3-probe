# AUM's user interface, screen by screen

What every control in [AUM](https://kymatica.com/aum) opens, and how to reach it.
Measured on AUM 1.4.8 by driving it from Linux with [`scripts/ipad`](../scripts/ipad)
([ipad-automation.md](ipad-automation.md)). AUM's own user guide is built in
(**Menu → HELP**), and its full text also shows up in `scripts/ipad tree aum` while
Help is open.

Positions are in **points** (what `tap-at` takes), not screenshot pixels. `W` and
`H` are the window size that `scripts/ipad size aum` prints; AUM rotates with the
iPad.

> Public-repo rule: this file names no sessions, devices, or rig data. Take your own
> screenshots to see your session; keep them out of this repository.

## Top bar

| Control | Where | Opens |
|---|---|---|
| Tempo `♩120` | left, (30, 30) | the tempo bar (see [Tempo and clock](#tempo-and-clock)) |
| Rewind, play, record | (111, 33), (156, 33), (201, 33) | transport (see [Transport and recording](#transport-and-recording)) |
| Main meter | centre | **Meter Sources**: hardware input/output, IAA/Audiobus outputs 1–8, mix busses, channel inputs/outputs |
| DSP % and battery | (W−180, 30) | **Engine Info** |
| Navigator `⛶` | (W−125, 33) | the Navigator side panel; long-press hides or unhides all plugin windows |
| MIDI routing `⊂⊃` | (W−75, 33) | the MIDI routing matrix (tap again to close) |
| Menu `☰` | (W−25, 33) | the main menu side panel |

The four right-hand buttons sit at the same offsets from the right edge in portrait
and landscape. The keyboard button is at the bottom left, about (52, H−17).

## Mixer

Channel strips scroll sideways, 242 points apart; the big square **+** tile at the
right end adds a channel. A MIDI strip holds MIDI nodes; an audio strip holds, top to
bottom: source node, insert slots (84 points apart), fader, M/S, output node, and the
record-arm **R**. New channels are titled `CHAN n` / `MIDI n`, then `n: <source>` once
a source is loaded.

| Gesture | Result |
|---|---|
| Tap the **+** tile | **AUDIO**, **MIDI**, **IMPORT**. The menu closes by itself after a few seconds, so tap the item right away |
| Tap a channel title | **Edit Channel** (see [Edit Channel](#edit-channel)) |
| Drag a channel title up about 100 points, then sideways, hold, release | moves the channel; numbers follow the new order |
| Tap the dB label above a fader | **Set level** dialog (number entry) |
| Drag the fader | level (123 points down from 0 dB gave −8.4 dB) |
| Double-tap the fader | back to Settings → Fader Level (0 dB by default) |
| Tap M, S, R | mute, solo, record-arm (R turns into **REC**; the record button shows the armed count) |
| Tap `≡` left of a plugin node | that node's MIDI sources and filters, with shortcuts to keyboard, MIDI controls and filter. An orange dot on `≡` means MIDI is connected |
| Tap a node's three dots | makes that point the main meter source (e.g. `Ch 2 IN`) |
| Tap a plugin node | its plugin window (see [Plugin window](#plugin-window)) |
| Tap a built-in node | its settings popover (see [Built-in nodes](#built-in-nodes)) |
| Tap an output node | **Destinations**: Hardware Output, IAA / Audiobus Output, Mix Bus |
| Tap an empty slot `+` | node picker (see [Node pickers](#node-pickers)) |
| Double-tap the empty area below the last insert | adds an empty slot |
| Scroll the insert column up | reveals the orange **+1** at its bottom, which adds a slot |
| Long-press a source node | **SELECT**, **REPLACE**, **RELOAD** |
| Long-press an insert node | **POST FADER**, **PRE FADER**, **SELECT**, **REPLACE**, **RELOAD**; **SWAP** while another node is selected |
| Long-press an empty slot | **POST FADER**, **PRE FADER**; **REMOVE SLOT** once a strip has two or more slots; **COPY HERE** / **MOVE HERE** after a SELECT |
| Swipe a node left (90 points) | bypasses it and shows an orange eject `⏏`; swiping it back right un-bypasses it |
| Tap `⏏` | removes the node at once; with Settings → Confirm Eject on, **Eject node?** asks first (**Always**, **OK**, **Cancel**) |
| Press a node, move 90 points right, hold | shows the node's DSP % and latency (e.g. `0.0% • +12 ms`, its name, and up/down arrows); moving up or down from there reorders it, and the fader wire follows |
| Knob next to a node | the node's main parameter (its name is printed above it; the value shows while dragging) |
| Double-tap the mixer background | hide or unhide all plugin windows |

**SELECT** makes the node glow. **COPY HERE** duplicates it into the empty slot,
**MOVE HERE** moves it there, **SWAP** exchanges it with the long-pressed node.
**REPLACE** opens the node picker and puts the new node in the same slot. **RELOAD**
reloads it in place with no visible change. **POST FADER** / **PRE FADER** move the
line from the fader to that node's input or output.

### Edit Channel

The popover titled **EDIT CHANNEL n**:

- top left: the channel's MIDI controls; top right: the **bookmark** (yellow when set).
- the name field: a custom name replaces the whole title, number included. Return
  applies it.
- **DUPLICATE** inserts a copy right after the channel, with its nodes, state,
  bookmark and MIDI mappings; the channels after it are renumbered.
- **REMOVE CHANNEL** turns into a blue **TAP TO CONFIRM**; a second tap within about
  a second removes the channel.

### Import and restore

**IMPORT** on the **+** tile opens a popover: **Restore Removed Channel** (with the
time it was removed) and every session file, with a search field. Restore appends the
last removed channel at the end of the mixer. Tapping a session shows **Select
channels to import**: each channel with its type and node count (`AUDIO, 6 NODES`),
all ticked; tap a row to untick it. **IMPORT n CHANNELS** appends them; a MIDI channel
imported next to an existing one gets the next free number.

## Node pickers

An empty **source** slot (only in a new audio channel) opens **SOURCES**:

- **Hardware**: Hardware Input (each input, stereo pairs and mono; keep such a
  channel muted, the built-in microphone feeds back).
- **Plugins**: Audio Unit Extension (instruments, grouped by company; pull down for
  search, which filters as you type), Multi-bus Audio Unit Instances.
- **AUM**: File Player, Mix Bus (`Receive from Bus A` …; each bus says `UNUSED` or how
  many signals it gets, and shows its custom name).
- **External**: Inter-App Audio (`NO STATE SAVING`), Audiobus Source.
  **Kymatica**: More Source Apps.

An empty **insert** slot opens **INSERTS & EFFECTS**:

- **Plugins**: Audio Unit Extension (effects; Apple's own AUs such as AUDelay or
  AULowPassFilter are listed when Settings → Apple Plugins is on), Multi-bus Audio Unit
  Instances.
- **Signal processing**: Stereo Processing (Stereo Balance, Stereo to Mono, Stereo
  Panning, Mid/Side Balance, Mid/Side-Stereo Convert, Invert Phase), Filter & EQ
  (Parametric EQ, Low-shelf, High-shelf, Low-pass, High-pass, LP/HP, All-pass 1st and
  2nd order), Dynamics (Gain, Hard Clip, Saturation, Peak Limiter).
- **Sends**: Bus Send (`Send to Bus A` …), Hardware Send (`Send to <output>` for each
  output, stereo and mono).
- **Utilities**: Time Offset. **External**: Inter-App Audio. **Kymatica**: More
  Effect Apps.

A **MIDI** strip slot opens **MIDI PROCESSORS**: Audio Unit MIDI Processor, Audio
Unit Extension, MIDI Bus. A new MIDI strip shows a hint: MIDI-only nodes produce no
audio.

## Built-in nodes

Short names on the nodes: `BAL`, `MONO`, `PAN`, `M/S`, `MS-LR`, `INV`; `PAR`, `LP`;
`GAIN`, `CLIP`, `LIM`; the Time Offset node shows its value (`+0.2 ms`). Most have a
knob to their left; Invert Phase has `L ⌀` and `R ⌀` toggles instead.

| Node | Tap opens |
|---|---|
| Parametric EQ | FREQ, Q, GAIN knobs. Tap a value for a number dialog (`Freq (Hz)`, **Cancel** / **Set**) |
| Low-pass Filter | FREQ, RESO |
| Gain | GAIN |
| Peak Limiter | ATTACK (12 ms), DECAY (24 ms), PRE-GAIN |
| Time Offset | `Time Offset (ms) ‹ +0.0 ›`, 0.1 ms per arrow tap |
| Bus Send, bus receive | **MIX BUS A NAME & COLOR**: custom short name, **CUSTOMIZE NODE COLOR** (a colour wheel, a VALUE slider and a swatch), **SAVE**. Name and colour apply to every node of that bus |
| Hardware Send | the INSERTS & EFFECTS picker (to replace it); its knob is the send level |
| MIDI Bus | **MIDI BUS NAME & COLOR** (custom colour on from the start). The **ENABLED** toggle sits left of the node |

## File Player

The node reads **TAP TO LOAD** until a file is loaded, then shows a circular
position display; the **PLAY ENABLE** toggle sits left of it. Tap the node for
**FILE PLAYER**:

- **Selected file**: the top row opens **SOUNDFILES**, AudioShare's folders (including
  AUM Recordings); a file loads at once. Duration and Format (`WAVE (LPCM) · 2 ch ·
  16 bit · 48000 Hz`) follow.
- **Options**: Loop, Sync (ON/OFF), Original BPM, Number of Beats, Rate, Beat Offset,
  Normalize. With Loop and Sync on, Number of Beats is derived from the file (an
  8-second take at 120 BPM gave 16).

The value buttons step by tap, in large jumps (one tap set Original BPM from 120 to
999, Number of Beats once jumped to 99999); the guide says double-tap types a value.
The player runs with the transport.

## Plugin window

The title bar holds, left to right:

| Button | Opens |
|---|---|
| Keys | the built-in keyboard, routed to this plugin only (turns yellow; tap again to unlink) |
| Route | the plugin's MIDI sources, **All Notes Off**, MIDI filters |
| MIDI controls | Bypass, Show & Front, Show/Hide, Preset Load, every AU parameter. The gear opens **Plugin Options** (clock ratio, clock factor); the radiating icon (or a long-press on the button) starts the **Control Finder**: tweak a control in the plugin to jump to its mapping |
| Presets | factory and user presets; **+** saves one |
| Title | long-press: instance name and node colour |
| Power | bypass: the icon turns red and the frame is hatched |
| Window mode | **DEFAULT**, **CUSTOM**, **MAXIMIZED**, **FULLSCREEN**; ✓ marks the current mode, `‧` the previous one |
| `✕` | close |

Effects without MIDI input show only MIDI controls and Presets on the left.

- **Custom**: drag the title bar to move the window and the corner handle (bottom
  right) to resize it; the plugin's view is cropped, not scaled.
- **Double-tap the title bar**: switch to the previous mode (Custom ↔ Maximized); a
  custom position is kept.
- **Fullscreen** fills the screen above the keyboard tab (`▲ KEYS`). With Settings →
  Fullscreen Exit on **BUTTONS**, a `✕` (close) sits at the top of the left edge and a
  restore button at its bottom; restore returns to the previous mode. On **SWIPE**
  (the default) leaving takes an edge swipe.

## Built-in keyboard

The bar above the keys: **HIDE**, `∞` (toggle), `↔` scroll mode (drag to pick the
octaves), connect (the keyboard's MIDI inputs and outputs), gear (MIDI send channel,
centre velocity, velocity range).

## Tempo and clock

The tempo bar replaces the top-left: close, **TAP**, `‹ ♩120 ›` (arrows step
0.1 BPM), metronome toggle (green when on), and `•••` **Clock Options**; the
transport moves right to about (385, 33).

- **TAP**: the tempo follows the taps.
- Drag the value sideways: 82 points to the right added 13 BPM.
- Double-tap the value: **Edit Value** dialog (number, **Cancel** / **Set**).

**Clock Options**:

- Time Signature (`4 / 4`), Pre-roll (`OFF`, `1 bar` …, stepper).
- **Transport MIDI Control**: Receive MMC, Rewind when stopped, and mappable
  actions (rewind, start, stop/rewind, toggle play, toggle record, previous/next bar,
  tap tempo, tempo, **Tempo Presets** with ADD TEMPO, metronome on/off).
- Sync Quantum (`1 bar`); **Ableton Link** (enable, notifications, Sync Start/Stop,
  peers); Link Offset; **MIDI Clock Send** (send clock, song position pointer, latency
  compensation None/Output/Input, offset, destinations).
- Metronome level, output, and during-pre-roll-only.

## Transport and recording

- **Play / pause**, **rewind** to 001:1. Drag sideways on the transport to locate, in
  whole bars (95 points to the right went from bar 1 to bar 3).
- **Long-press play** starts or stops the transport too; per the guide it does so
  without starting or stopping Link peers.
- **Record** with the transport stopped starts the transport and records every armed
  channel; with a pre-roll of 1 bar the counter starts at `-01:1` and recording at
  001:1. The armed channel's REC flashes and shows the position. Tap record again
  to stop: **RECORDING FINISHED** and a **Recording saved to FILES menu** hint.
- **Record while playing** waits for the next sync quantum to start, and a second tap
  waits for the next one to stop.
- **Long-press record**: **Un-arm recording** asks whether to turn off recording
  for all channel strips (**No** / **Yes**).

Each take is a WAV (bit depth from Settings → Recording) in FILES → Recordings, in a
folder named after the session, called `<n>. <channel title> - <tempo> bpm - <take>`.
Tapping it opens **PREVIEW** (session, file name, rewind, play, share, position and
remaining time). Share opens the iOS share sheet with AUM's own **Copy**, **Show in
AudioShare** and **Add FilePlayer**.

## Engine Info

DSP % opens **Engine Info**: sample rate, buffer size and duration, input/output
count, device and round-trip latencies, latency compensation, IAA host ports, and an
advanced section listing the audio session's inputs and outputs. The share button
copies it all to the pasteboard. **Node Statistics** shows per node: DSP Load
(buffer %, total %, time, max time; PAUSE), Latency, Init/Load time, State Save time.

## Navigator

Tabs **CHANNELS**, **PLUGINS**, **ALL** (striped rows are bypassed); the bookmark
toggle (top right) lists only bookmarked channels; the eye hides or unhides all plugin
windows. Tap a channel to scroll the mixer to it, a node to show its window. Tap the
mixer to close the panel.

## MIDI routing

The matrix: sources along the top, destinations on the right; tap a cell to connect
(an L-shaped wire runs from the source to the destination) and tap it again to
disconnect. Hatched cells pair an endpoint with itself. Unavailable endpoints stay
listed while they have connections.

| Control | Opens |
|---|---|
| A source's name | its destination list; the icon at the top left **swaps** all connections with another endpoint |
| A destination's name | **<name> Destination**: Connect MIDI Sources, **All Notes Off**, and the MIDI filter. The funnel (top right) jumps to the filter |
| Corner handle | drag to resize the matrix, tap to minimise it |
| Wi-Fi | Network MIDI: session on/off, connection policy, hosts |
| Bluetooth | Central (the iOS Bluetooth MIDI device list) and Peripheral (advertise this iPad) |

The filter: **Channel Filter** (16 toggles, **NONE**, **ALL**), **Note Range**
(`‹ C-1 (0) ›` → `‹ G9 (127) ›`), **Transpose** (`«` `‹` `+0 semitones` `›` `»`),
**CC Filter** (a grid of 128 dots), **Message Type** (PASS or BLOCK for Note On/Off,
Pitch Bend, Program Change, Poly and Channel Aftertouch, System Real-time, Common
and Exclusive). Renaming applies to CoreMIDI hardware endpoints only (the guide: tap
the name, then the Name row); built-in, virtual and network endpoints have no Name
row.

## Main menu

The `☰` side panel shows the session name and an icon grid. Its back arrow is at the
top left, and the icon at the top right closes it.

| Item | Opens |
|---|---|
| FILES | **Sessions** (sort by name, last saved or last opened; home; EDIT shows delete buttons; folders; each row shows when it was saved; tapping a session **loads** it), **Recordings** (one folder per session), **Restore Previous State**, an AudioShare link |
| SAVE | session name, folder picker (with new folder), **SAVE SESSION** |
| CLEAR | clears the session after a second tap (see below) |
| NOTES | a plain-text session notes editor |
| ABOUT | version, plus share, like, contact and website links |
| HELP | AUM's User's Guide with **Find Text** and **Open in web browser** |
| SETTINGS | see [Settings](#settings) |
| MIDI ROUTE | the routing matrix |
| MIDI CTRL | see [MIDI Control](#midi-control) |
| `$` | the tip jar (in-app purchases) |

- **CLEAR** shows a brief **Sure?** and clears only on a second tap within about a
  second.
- **SAVE**: Return in the name field saves at once. **SAVE SESSION** under an existing
  name turns into **OVERWRITE?**, which saves on a second tap.
- **Long-press a session** in FILES: the iOS share sheet with AUM's **Copy URL** and
  **Import Channels** (the [import](#import-and-restore) channel list, inside the
  panel); its "more" entry adds **Rename** (a **RENAME** dialog, **Cancel** / **OK**;
  the file is renamed at once).

## Settings

- **Audio engine**: Sample Rate and Buffer Size each open a list of *preferred*
  values (192 … 44.1 kHz; 32 … 2048 frames with their duration). The button shows the
  current value, the list marks the preferred one with ✓ and the current one as
  `CURRENT SAMPLE RATE`. A rate the hardware can't run brings **Could not set sample
  rate**. Min. Latency is a stepper (`‹ 0 ms ›`, 1 ms steps).
- **Mic & speaker**: output route (the system AirPlay picker), input source and polar
  pattern, Input Gain (`‹ 50 % ›`, 1 % steps), High Quality (measurement mode).
- **Recording**: bit depth (INT 16, INT 24, FLOAT 32), latency compensation for
  hardware inputs.
- **Channel defaults**: Fader Level, First Effect Slot (PRE/POST), Send Amount.
- **Audiobus**: auto-add sources. **Wireless MIDI**: Bluetooth Central, Bluetooth
  Peripheral, Network MIDI.
- **Plugins**: Grid Snap (windows snap to a grid: a drag of (57, 45) landed at
  (38, 53), a small one snapped back), Initial Size (DEFAULT, MAXIMIZED …), Fullscreen
  Exit (SWIPE or BUTTONS), Apple Plugins.
- **Appearance**: Show Status Bar (moves all of AUM down by about 32 points),
  Confirm Eject, Reset Help Hints (**OK**, then a disabled **Done!**).

Each toggle shows its new value in place.

## MIDI Control

A filter (**ALL**, **ASSIGNED**, **UNUSED**), a **No MIDI Source! Tap to connect**
shortcut to the MIDI Control destination, and collections:

- **Transport**: Parameters, the same items as Transport MIDI Control.
- **System**: Switch to AUM, Hide/Unhide Plugins, Unsolo Channels, **Session Load**
  (actions stored globally, not in the session: Force Link Tempo and **ADD SESSION**).
- **Channels**: one collection per channel. **Channel controls** (Scroll to Channel,
  Volume, Mute, Solo, Rec enable), then one entry per node. Built-in nodes offer only
  Bypass; plugins offer Bypass, Show & Front Plugin, Show / Hide Plugin, **Preset
  Load** (ADD PRESET picks from the plugin's factory and user presets) and their
  parameter groups (an Apple AU lists `global`: Cutoff Frequency, Resonance, each with
  its range and current value). Some AUs expose no parameters.

Every new audio channel gets a Volume mapping (CC 7, on the MIDI channel matching
the strip's number when it was added), so ASSIGNED lists all audio channels. A
duplicated channel keeps the original's mapping, which the warning triangle below
then flags.

Tapping a control opens its mapping editor at the bottom: MIDI channel (OFF, CH
1–16, OMNI), message type (NOTE, CC, PC, PBEND, CHPRS), number with its name
(`7 Volume (MSB)`, `C4 (60)`), **LEARN** (shows **LEARNING** until a message arrives;
tap again to stop), and either a range button (`0 → 71 %`, opening a curve with
draggable end points; dragging the top one set −3.5 dB) or, for toggles, **INVERT** and
**CYCLE**. A yellow triangle with a count marks a message used more than once; tap it
for the list of parameters it drives. For plugin parameters, the knob icon at the
lower right makes that parameter the node's **main parameter**: it turns green and
the knob next to the node takes its name.

Each `⋮` menu:

| Where | Items |
|---|---|
| A group (Channels) | Set MIDI Channels, Clear All |
| A collection (Channel controls, a node) | Save, Load, Copy, Paste, Set MIDI Channels, Clear All |
| A user list (Tempo Presets, Preset Load) | Set MIDI Channels, Clear All, Delete All |

**Set MIDI Channels** asks for one channel (1–16, 0 for any) and applies it to every
mapping below. **Clear All** and **Delete All** act at once, without asking.
**Copy** / **Paste** carry mappings between collections of the same kind. **Save**
names a mapping file (**Save MIDI Mapping**); **Load** lists the saved files of that
kind (sort by name or last saved) and applies one with a tap. **ADD TEMPO** opens
**EDIT TEMPO** (`‹ ♩120 ›`, **DONE**) and adds a `120.0 BPM` row.

## Automating AUM

- **The tree has the text, not always the buttons.** Popovers and side panels do show
  up in `tree aum`, and list rows tap fine by label (`tap Recordings aum`). The
  main-menu icon grid does not: its captions (`FILES`, `SAVE`, …) are separate text
  below the icon, so `tap FILES aum` reports success and nothing opens. Tap the icon
  with `tap-at` instead. Most mixer buttons have no label at all; channel titles
  (`2: <plugin>`, `MIDI 1`), the dB labels, and `MUTE`, `SOLO`, `REC` do.
- **Closing things.** Tap outside a popover. The Navigator closes when you tap the
  mixer; the menu panel by its top-right icon.
- **Two-step buttons** (CLEAR, OVERWRITE?, REMOVE CHANNEL) need their second tap
  within about a second: `scripts/ipad confirm <x> <y> aum`.
- **Timing.** The **+** tile's menu closes by itself; tap AUDIO, MIDI or IMPORT right
  after opening it, with no `tree` in between. That is why IMPORT seemed to ignore
  taps in an earlier pass.
- **Drags.** Use `scripts/ipad drag` (it holds before releasing) to reorder nodes and
  channels, reveal a node's DSP % and latency, and move or resize plugin windows;
  `swipe` is enough for faders, knobs and scrolling.
- **Text.** `scripts/ipad type` fills the first text field (session and file names,
  bus names, number dialogs); confirm with the dialog's button by position, or
  `scripts/ipad enter` where Return applies (Save panel, channel name). Dialogs move
  up while the keyboard shows.
- **Plugin windows can hang WebDriverAgent** (seen with an Apple AU effect): avoid
  `tree` while one is open ([ipad-automation.md](ipad-automation.md)).
- **Controls that change or lose state:** CLEAR, tapping a session in FILES (loads
  it), SAVE SESSION and OVERWRITE?, REMOVE CHANNEL, eject `⏏`, Clear All, Delete All
  and Set MIDI Channels in MIDI Control, Rename in FILES, play (starts every synced
  plugin) and record (writes files). Take a screenshot before a `tap-at` near any of
  them.
