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
| Rewind, play, record | (111, 33), (156, 33), (201, 33) | transport; record starts recording every armed channel. Long-press record un-arms all |
| Main meter | centre | **Meter Sources**: hardware input/output, IAA/Audiobus outputs 1–8, mix busses, channel inputs/outputs |
| DSP % and battery | (W−180, 30) | **Engine Info** |
| Navigator `⛶` | (W−125, 33) | the Navigator side panel |
| MIDI routing `⊂⊃` | (W−75, 33) | the MIDI routing matrix (tap again to close) |
| Menu `☰` | (W−25, 33) | the main menu side panel |

The four right-hand buttons sit at the same offsets from the right edge in portrait
and landscape. The keyboard button is at the bottom left, about (52, H−17).

## Mixer

Channel strips scroll sideways; the big square **+** tile at the right end adds a
channel (**AUDIO**, **MIDI**, **IMPORT**). A MIDI strip holds MIDI nodes; an audio
strip holds, top to bottom: source node, insert slots, fader, M/S, output node, and
the record-arm **R**.

| Gesture | Result |
|---|---|
| Tap a channel title | **Edit Channel**: MIDI controls of the channel, bookmark, rename (inline text field), **DUPLICATE**, **REMOVE CHANNEL** |
| Tap the dB label above a fader | **Set level** dialog (number entry) |
| Tap M, S, R | mute, solo, record-arm (R turns into **REC**; the record button shows the armed count) |
| Tap `≡` left of a plugin node | that node's MIDI sources and filters, with shortcuts to keyboard, MIDI controls and filter. An orange dot on `≡` means MIDI is connected |
| Tap a node's three dots | makes that point the main meter source (e.g. `Ch 2 IN`) |
| Tap a plugin node | its plugin window (see [Plugin window](#plugin-window)) |
| Tap an output node | **Destinations**: Hardware Output, IAA / Audiobus Output, Mix Bus |
| Tap an empty slot `+` | node picker (see [Node pickers](#node-pickers)) |
| Long-press a source node | **SELECT**, **REPLACE**, **RELOAD** |
| Long-press an insert node | **POST FADER**, **PRE FADER**, **SELECT**, **REPLACE**, **RELOAD** |
| Long-press an empty slot | **POST FADER**, **PRE FADER**; **REMOVE SLOT** once a strip has two or more slots; **COPY HERE** / **MOVE HERE** after a SELECT |
| Swipe a node left | bypasses it and shows an orange eject `⏏`; tapping `⏏` removes the node |
| Knob next to a node | the plugin's main parameter (its name is printed above it) |
| Double-tap the mixer background | hide or unhide all plugin windows |

## Node pickers

An empty **insert** slot opens **Inserts & Effects**:

- **Plugins**: Audio Unit Extension (grouped by company; sort by company, name or last
  used; pull down for search), Multi-bus Audio Unit Instances.
- **Signal processing**: Stereo Processing (balance, stereo to mono, panning,
  mid/side balance, mid/side–stereo convert, invert phase), Filter & EQ (parametric
  EQ, low/high shelf, low/high pass, LP/HP, all-pass 1st/2nd order), Dynamics (gain,
  hard clip, saturation, peak limiter).
- **Sends**: Bus Send (Bus A …), Hardware Send (each output, stereo and mono).
- **Utilities**: Time Offset. **External**: Inter-App Audio. **Kymatica**: More
  Effect Apps.

A **MIDI** strip slot opens **MIDI Processors**: Audio Unit MIDI Processor, Audio
Unit Extension, MIDI Bus. The node picker for an audio **source** (instruments,
generators, hardware input, file player, bus) only appears on an empty source slot,
that is in a new channel.

## Plugin window

The title bar holds, left to right:

| Button | Opens |
|---|---|
| Keys | the built-in keyboard, routed to this plugin only (turns yellow; tap again to unlink) |
| Route | the plugin's MIDI sources, **All Notes Off**, MIDI filters |
| MIDI controls | Bypass, Show & Front, Show/Hide, Preset Load, every AU parameter. The gear opens **Plugin Options** (clock ratio, clock factor); the radiating icon (or a long-press on the button) starts the **Control Finder**: tweak a control in the plugin to jump to its mapping |
| Presets | factory and user presets; **+** saves one |
| Title | long-press: instance name and node colour |
| Power | bypass |
| Window mode | Default, Custom, Maximized, Fullscreen |
| `✕` | close |

Drag the title bar to move the window and the corner handle to resize it.

## Built-in keyboard

The bar above the keys: **HIDE**, `∞` (toggle), `↔` scroll mode (drag to pick the
octaves), connect (the keyboard's MIDI inputs and outputs), gear (MIDI send channel,
centre velocity, velocity range).

## Tempo and clock

The tempo bar replaces the top-left: close, **TAP**, `‹ ♩120 ›` (arrows step
0.1 BPM; drag the value; double-tap to type it), metronome toggle (green when on),
and `•••` **Clock Options**:

- Time Signature, Pre-roll.
- **Transport MIDI Control**: Receive MMC, Rewind when stopped, and mappable
  actions (rewind, start, stop/rewind, toggle play, toggle record, previous/next bar,
  tap tempo, tempo, **Tempo Presets** with ADD TEMPO, metronome on/off).
- Sync Quantum; **Ableton Link** (enable, notifications, Sync Start/Stop, peers);
  Link Offset; **MIDI Clock Send** (send clock, song position pointer, latency
  compensation None/Output/Input, offset, destinations).
- Metronome level, output, and during-pre-roll-only.

## Engine Info

DSP % opens **Engine Info**: sample rate, buffer size and duration, input/output
count, device and round-trip latencies, latency compensation, IAA host ports, and an
advanced section listing the audio session's inputs and outputs. The share button
copies it all to the pasteboard. **Node Statistics** shows per node: DSP Load
(buffer %, total %, time, max time; PAUSE), Latency, Init/Load time, State Save time.

## Navigator

Tabs **CHANNELS**, **PLUGINS**, **ALL** (striped rows are bypassed); the bookmark
toggle lists only bookmarked channels; the eye hides or unhides all plugin windows.
Tap a channel to scroll the mixer to it, a node to show its window. Tap the mixer to
close the panel.

## MIDI routing

The matrix: sources along the top, destinations on the right; tap a cell to connect
or disconnect. Unavailable endpoints stay listed while they have connections.

| Control | Opens |
|---|---|
| A source's name | its destination list; the icon at the top left **swaps** all connections with another endpoint |
| A destination's name | its sources, **All Notes Off**, and the MIDI filter (channels, note range, transpose, CC filter, pass/block per message type); the funnel jumps to the filter |
| Corner handle | drag to resize the matrix, tap to minimise it |
| Wi-Fi | Network MIDI: session on/off, connection policy, hosts |
| Bluetooth | Central (the iOS Bluetooth MIDI device list) and Peripheral (advertise this iPad) |

## Main menu

The `☰` side panel shows the session name and an icon grid. Its back arrow is at the
top left, and the icon at the top right closes it.

| Item | Opens |
|---|---|
| FILES | **Sessions** (sort by name, last saved or last opened; home; EDIT shows delete buttons; folders; tapping a session **loads** it; long-press opens the share sheet with rename and copy), **Recordings** (folders of WAV files), **Restore Previous State**, an AudioShare link |
| SAVE | session name, folder picker (with new folder), **SAVE SESSION** |
| CLEAR | clears the session |
| NOTES | a plain-text session notes editor |
| ABOUT | version, plus share, like, contact and website links |
| HELP | AUM's User's Guide with **Find Text** and **Open in web browser** |
| SETTINGS | see [Settings](#settings) |
| MIDI ROUTE | the routing matrix |
| MIDI CTRL | see [MIDI Control](#midi-control) |
| `$` | the tip jar (in-app purchases) |

## Settings

- **Audio engine**: sample rate and buffer size (each a list of preferred values),
  minimum latency.
- **Mic & speaker**: output route (the system AirPlay picker), input source and polar
  pattern, input gain, high-quality (measurement) mode.
- **Recording**: bit depth (16-bit int, 24-bit int, 32-bit float), latency
  compensation for hardware inputs.
- **Channel defaults**: fader level, first effect slot (pre/post), send amount.
- **Audiobus**: auto-add sources. **Wireless MIDI**: Bluetooth Central, Bluetooth
  Peripheral, Network MIDI.
- **Plugins**: grid snap, initial window size, fullscreen exit (swipe or buttons),
  Apple plugins. **Appearance**: status bar, confirm eject, reset help hints.

## MIDI Control

A filter (all, assigned, unused), a **No MIDI Source! Tap to connect** shortcut to
the MIDI Control destination, and collections:

- **Transport**: the same items as Transport MIDI Control.
- **System**: Switch to AUM, Hide/Unhide Plugins, Unsolo Channels, **Session Load**
  (actions stored globally, not in the session; **ADD SESSION**, Force Link Tempo).
- **Channels**: one collection per channel, each with **Channel controls** (scroll to
  channel, volume, mute, solo, rec enable) and one collection per node.

Tapping a control opens its mapping editor: MIDI channel (OFF, 1–16, OMNI), message
type (NOTE, CC, PC, PBEND, CHPRS), number, **LEARN**, and **INVERT** or range. Each
collection's `⋮` menu has Save, Load, Copy, Paste, Set MIDI Channels and Clear All
(Delete All on user-added lists such as Tempo Presets).

## Automating AUM

- **The tree has the text, not always the buttons.** Popovers and side panels do show
  up in `tree aum`, and list rows tap fine by label (`tap Recordings aum`). The
  main-menu icon grid does not: its captions (`FILES`, `SAVE`, …) are separate text
  below the icon, so `tap FILES aum` reports success and nothing opens. Tap the icon
  with `tap-at` instead. Most mixer buttons have no label at all; channel titles
  (`2: <plugin>`, `MIDI 1`), the dB labels, and `MUTE`, `SOLO`, `REC` do.
- **Closing things.** Tap outside a popover. The Navigator closes when you tap the
  mixer; the menu panel by its top-right icon.
- **Gestures that don't come through.** IMPORT on the add-channel tile ignored every
  synthetic tap. A drag that starts on a node becomes a long-press (the slot menu), so
  the drag-right reveal of a node's DSP % and latency could not be reached. Avoid the
  plugin window's Fullscreen mode: leaving it takes an edge swipe, which iPadOS takes
  for its own gestures.
- **Controls that change or lose state:** CLEAR, tapping a session in FILES (loads
  it), SAVE SESSION, REMOVE CHANNEL, eject `⏏`, Delete All and Clear All in MIDI
  Control, play (starts every synced plugin) and record (writes files). Take a
  screenshot before a `tap-at` near any of them.
