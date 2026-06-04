# signalwave — the auv3-probe design language

The visual and UX identity for `auv3-probe`. The aesthetic is **Bauhaus ×
Signalwave**: the functional precision of a network/signal analyzer
(Wireshark / `nmap` for the iOS audio ecosystem) crossed with the tactile feel
of hardware patch routing.

It is a **built-not-bought, DIY** identity — an engineering terminal on a
retro-futuristic rig, not a glossy app-store product. Pure command-line energy:
direct, open, zero fluff. The name `auv3probe` is itself part of the brand —
lowercase, monospaced, sounds like a CLI tool.

## Principles

- **Schematic, not skeuomorphic.** Surfaces look screen-printed or etched —
  technical drawings and terminal glyphs, never glossy gradient buttons.
- **High contrast, low chroma.** Near-black field, one signal accent, muted grid
  lines. Restraint reads as instrument-grade.
- **No obfuscation.** Show the raw data. The UI exposes what a plugin is
  broadcasting (parameters, ranges, MIDI mappability) like an open book, so it
  can be mapped to physical hardware by hand.
- **Bold geometry, raw lines.** Thick strokes, hard edges, deliberate alignment
  to a grid. Utilitarian over decorative.

## Color palette

Restricted to a stark, high-contrast set reminiscent of early test equipment and
low-fi CRT monitors.

| Role | Color | Hex |
|------|-------|-----|
| Primary background | Deep Charcoal / Obsidian | `#121212` |
| Grid lines / dividers | Muted Slate | `#2A2A2A` |
| Signal accent (primary) | High-visibility Cyber Green | `#00FF66` |
| Signal accent (alt) | Industrial Amber / Orange | `#FF7A00` |

Pick **one** signal accent per surface and let the charcoal/slate do the rest.
Green reads "CRT terminal"; amber reads "lab test gear" — both are valid, but
mixing them dilutes the instrument feel. Text is the accent or a near-white on
charcoal; avoid mid-grays for foreground type.

## Typography

- **Monospaced, lowercase, minimal padding.** Type sits tight to the grid.
- Lowercase is intentional — it is the command-line register, not a marketing
  wordmark.
- Reserve color for signal; body text stays high-contrast monochrome.

## Logo / app icon motif

Not a generic waveform and not an app-store gradient button. Treat it as a
**terminal glyph** or a screen-printed schematic: a sharp **sine/square wave
intercepting a solid circle** (the "probe" node), or a minimalist **patch-bay
grid with one line breaking out**.

```text
+-------------------+
|  _   _   _   _    |
| / \_/ \_/ \_/ \   |   <-- high-contrast vector wave
| ------O-------    |   <-- intersecting a solid node (the probe)
|                   |
| auv3probe         |   <-- sharp, lowercase monospace text
+-------------------+
```

Construction notes:

- Monochrome, high-contrast, bold geometry, raw utilitarian lines.
- The wave is the signal; the solid circle is the probe tapping it. Keep the
  intercept point obvious.
- For the **app icon**, the artwork sits full-bleed on the charcoal field with
  **no transparency** (iOS rounds the corners itself — app icons must be opaque,
  no alpha channel).

> **Current state:** the committed app icon
> (`Resources/Assets.xcassets/AppIcon.appiconset/`) is a colorful placeholder
> cut from a generated image and does **not** yet follow signalwave. Replacing it
> with a monochrome charcoal + single-accent glyph per this doc is the intended
> direction.

## UI & UX vibes

This is the nerve center for a physical + digital rig (synths, bass pedals, iPad
routing), so the interface should feel open-source and modular.

- **The "sniffer" console.** A live, scrolling terminal view that lists every
  AUv3 plugin discovered on the system and exposes its parameters, ranges, MIDI
  mappability and state — like an open packet capture.
- **No obfuscation.** Raw data on display. Let the user see exactly what a plugin
  exposes so it maps cleanly onto physical hardware controllers.
- **Grid mapping.** A clean, matrix-style patch bay: rows = physical hardware
  (synths, pedalboard), columns = scanned iPad AUv3 hosts / effects.

The shipped SwiftUI screens implement this language directly (no longer stock
`Form`s): a forced-dark charcoal field, monospaced lowercase chrome, a single
cyber-green signal accent, slate hairline dividers, and capture-style lists with
armed-row signal bars. UI chrome is lowercased while raw data (unit names, FourCC
codes, parameter counts) is shown verbatim. The palette, fonts, wave glyph, and
shared components live in `Sources/Theme.swift`; the app shell is
`Sources/RootView.swift` (the audio-units console is `Sources/AudioUnitsView.swift`,
the AUM-sessions ferry is `Sources/AUMSessionsView.swift`). A console/matrix
patch-bay layout (rows = hardware, columns = scanned hosts) remains a future step.

### Tap to inspect — the per-unit sniffer view

The "sniffer console that exposes what each unit broadcasts" is realized by the
**inspector overlays** (`Sources/AudioUnitInspectorView.swift` for audio units,
`Sources/AUMSessionInspectorView.swift` for AUM sessions): tapping a row opens a
read-only sheet that lays its structure bare. It is the most direct expression of
the **no-obfuscation** principle — you see the exact data a send would POST, on
the device, before sending.

Visually it is the same language carried into a `.sheet`: charcoal field, mono
lowercase chrome, a single green signal accent, slate hairlines, hard edges. The
summary doubles as a **patch-bay index** — a row of tappable chips (parameter
groups and preset lists) that isolate one slice of the signal map at a time, the
schematic grid-mapping instinct applied to a single unit.

The interaction mechanics, the section-by-section breakdown, and the
lazy-rendering performance design live in
[design.md](design.md#inspect-before-send-tap-to-inspect) — this section only
covers the design-language angle.

## See also

- [design.md](design.md) — architecture and data flow.
- Original concept brief (the source of this palette, typography and motif).
