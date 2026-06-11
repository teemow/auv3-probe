import SwiftUI
import ProbeKit

// Mixer/synth-style rendering of the session control surface. Each session
// device becomes a rack module whose controls are recognized and laid out the
// way a console presents them:
//
// - transport-mapped controls   → a transport cluster with the standard glyphs
// - level/volume-like faders    → vertical channel-strip faders
// - other continuous controls  → rotary potentiometers in a wrapping grid
// - mute/solo/rec-arm toggles  → console M/S/R switches
// - other two-state toggles    → LED switches
// - enums                      → patch-style selectors (prev / readout / next)
// - triggers/presets           → momentary pads
//
// All in the signalwave language (charcoal field, slate grid, green signal
// accent, lowercase monospace chrome). The surface stays write-only: AUM gives
// no feedback path, so every widget's state is local and just remembers the
// last sent value.

// MARK: - Name heuristics

/// Session mapping names arrive as wire identifiers ("adsr0_attack_k",
/// "transport_rewind"). Strip the one-letter widget-type suffix and the
/// underscores for display; the raw name stays the message identity.
private func surfaceDisplayName(_ raw: String) -> String {
    var name = raw
    for suffix in ["_k", "_t", "_f", "_b"] where name.hasSuffix(suffix) {
        name = String(name.dropLast(suffix.count))
        break
    }
    return name.replacingOccurrences(of: "_", with: " ")
}

/// The lowercase words of a wire name ("tape_stop_t" → ["tape", "stop", "t"]).
/// Heuristics match whole words so "tap" never matches "tape".
private func surfaceNameWords(_ raw: String) -> Set<String> {
    Set(raw.lowercased().split(separator: "_").map(String.init))
}

/// Controls mapped to the host transport (or tap tempo) get the dedicated
/// transport cluster instead of generic pads/switches.
private func isTransportControl(_ name: String) -> Bool {
    !surfaceNameWords(name).isDisjoint(with: ["transport", "tap"])
}

/// Continuous controls that read as a channel level keep the long-throw fader;
/// everything else continuous becomes a potentiometer.
private func isLevelControl(_ name: String) -> Bool {
    !surfaceNameWords(name).isDisjoint(with: ["level", "volume", "vol", "gain", "master", "fader"])
}

/// The rec-arm function words, a subset of `consoleSwitchWords`.
private let consoleRecWords: Set<String> = ["rec", "record", "recarm", "arm"]

/// Every channel-function word behind the console M/S/R switches. Shared with
/// `SurfaceConsoleSwitch`'s caption so the two lists cannot drift.
private let consoleSwitchWords: Set<String> = consoleRecWords.union(["mute", "solo"])

/// Mixer channel functions rendered as console letter switches.
private func consoleSwitchKind(_ name: String) -> (letter: String, accent: Color)? {
    let words = surfaceNameWords(name)
    if words.contains("mute") { return ("M", Signalwave.amber) }
    if words.contains("solo") { return ("S", Signalwave.green) }
    if !words.isDisjoint(with: consoleRecWords) { return ("R", Signalwave.amber) }
    return nil
}

private extension ControlSurfaceDescriptor.Control {
    /// The off/on value pair of a two-state toggle, nil for anything else.
    /// `values` is daemon-ordered by wire value, so `off` is the state a
    /// write-only widget starts in (unsent). Lets each toggle view validate
    /// its own input instead of trusting the grouping in
    /// `SurfaceDeviceModule` from afar.
    var toggleStates: (off: ControlSurfaceDescriptor.NamedValue, on: ControlSurfaceDescriptor.NamedValue)? {
        guard let values = values, values.count == 2 else { return nil }
        return (values[0], values[1])
    }
}

/// Transport glyph + sort rank, in console order: rewind, play, stop,
/// play/stop toggle, record, tap tempo.
private func transportGlyph(_ name: String) -> (icon: String, rank: Int) {
    let words = surfaceNameWords(name)
    if !words.isDisjoint(with: ["rewind", "return"]) { return ("backward.end.fill", 0) }
    if !words.isDisjoint(with: ["toggle", "playpause"]) { return ("playpause.fill", 3) }
    if !words.isDisjoint(with: ["start", "play"]) { return ("play.fill", 1) }
    if words.contains("stop") { return ("stop.fill", 2) }
    if !words.isDisjoint(with: ["rec", "record"]) { return ("record.circle", 4) }
    if words.contains("tap") { return ("metronome.fill", 5) }
    return ("bolt.fill", 6)
}

// MARK: - Device module

/// One session-derived device rendered as a rack module. Expansion is
/// per-module local state (reset when a new surface arrives via the parent's
/// `.id`).
struct SurfaceDeviceModule: View {
    let device: ControlSurfaceDescriptor.Device
    let model: BrainViewModel
    @State private var expanded: Bool

    init(device: ControlSurfaceDescriptor.Device, expandedInitially: Bool, model: BrainViewModel) {
        self.device = device
        self.model = model
        _expanded = State(initialValue: expandedInitially)
    }

    // MARK: Control grouping

    private struct Groups {
        var transport: [ControlSurfaceDescriptor.Control] = []
        var faders: [ControlSurfaceDescriptor.Control] = []
        var knobs: [ControlSurfaceDescriptor.Control] = []
        var switches: [ControlSurfaceDescriptor.Control] = []
        var selectors: [ControlSurfaceDescriptor.Control] = []
        var pads: [ControlSurfaceDescriptor.Control] = []
        var unsupported: [ControlSurfaceDescriptor.Control] = []
    }

    private var groups: Groups {
        var g = Groups()
        for control in device.controls {
            switch control.widgetKind {
            case .fader:
                if isLevelControl(control.name) { g.faders.append(control) }
                else { g.knobs.append(control) }
            case .toggle:
                let count = control.values?.count ?? 0
                if count == 2 {
                    if isTransportControl(control.name) { g.transport.append(control) }
                    else { g.switches.append(control) }
                } else if count > 0 {
                    g.selectors.append(control)
                } else {
                    g.unsupported.append(control)
                }
            case .picker:
                if (control.values ?? []).isEmpty { g.unsupported.append(control) }
                else { g.selectors.append(control) }
            case .trigger, .preset:
                if isTransportControl(control.name) { g.transport.append(control) }
                else { g.pads.append(control) }
            case nil:
                g.unsupported.append(control)
            }
        }
        g.transport.sort { transportGlyph($0.name).rank < transportGlyph($1.name).rank }
        return g
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Rectangle()
                    .fill(Signalwave.grid)
                    .frame(height: 1)
                content
                    .padding(12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Signalwave.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Signalwave.grid, lineWidth: 1)
        )
    }

    /// The module nameplate: device name etched on the rack ear.
    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Signalwave.green)
                Text(device.name)
                    .font(Signalwave.mono(.callout, weight: .semibold))
                    .foregroundStyle(Signalwave.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(device.controls.count)")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
    }

    private var content: some View {
        let g = groups
        return VStack(alignment: .leading, spacing: 16) {
            if !g.transport.isEmpty {
                WrapLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(Array(g.transport.enumerated()), id: \.offset) { item in
                        SurfaceTransportButton(control: item.element, model: model)
                    }
                }
            }
            if !g.faders.isEmpty {
                WrapLayout(spacing: 12, lineSpacing: 12) {
                    ForEach(Array(g.faders.enumerated()), id: \.offset) { item in
                        SurfaceChannelStrip(control: item.element, model: model)
                    }
                }
            }
            if !g.knobs.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 10, alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    ForEach(Array(g.knobs.enumerated()), id: \.offset) { item in
                        SurfaceKnob(control: item.element, model: model)
                    }
                }
            }
            if !g.switches.isEmpty {
                WrapLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(Array(g.switches.enumerated()), id: \.offset) { item in
                        if let kind = consoleSwitchKind(item.element.name) {
                            SurfaceConsoleSwitch(control: item.element, model: model,
                                                 letter: kind.letter, accent: kind.accent)
                        } else {
                            SurfaceLedToggle(control: item.element, model: model)
                        }
                    }
                }
            }
            if !g.selectors.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(g.selectors.enumerated()), id: \.offset) { item in
                        SurfaceEnumSelector(control: item.element, model: model)
                    }
                }
            }
            if !g.pads.isEmpty {
                WrapLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(Array(g.pads.enumerated()), id: \.offset) { item in
                        SurfacePad(control: item.element, model: model)
                    }
                }
            }
            ForEach(Array(g.unsupported.enumerated()), id: \.offset) { item in
                HStack(spacing: 6) {
                    Text(surfaceDisplayName(item.element.name))
                        .font(Signalwave.mono(.caption))
                        .foregroundStyle(Signalwave.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("(\(item.element.widget) — unsupported)")
                        .font(Signalwave.mono(.caption2))
                        .foregroundStyle(Signalwave.dim)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - LED readout

/// A small LED-style value window: green monospace on a recessed near-black
/// field, the readout idiom shared by strips, knobs and selectors.
private struct LedReadout: View {
    let text: String
    var minWidth: CGFloat? = nil

    var body: some View {
        Text(text)
            .font(Signalwave.mono(.caption2, weight: .semibold))
            .foregroundStyle(Signalwave.green)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .frame(minWidth: minWidth)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Signalwave.bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Signalwave.grid, lineWidth: 1)
            )
    }
}

/// The control name as a scribble strip under a strip/knob.
private struct ScribbleLabel: View {
    let name: String
    let width: CGFloat

    var body: some View {
        Text(surfaceDisplayName(name))
            .font(Signalwave.mono(.caption2))
            .foregroundStyle(Signalwave.fg)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(width: width, height: 28, alignment: .top)
    }
}

private extension View {
    /// VoiceOver for the Canvas-drawn continuous controls (the native Slider
    /// they replaced had this for free): one adjustable element named after
    /// the control, stepping ~10% of the throw per adjustment (at least one
    /// wire step).
    func surfaceAdjustableAccessibility(control: ControlSurfaceDescriptor.Control,
                                        value: Binding<Double>,
                                        set: @escaping (Double) -> Void) -> some View {
        let range = control.faderRange
        let step = max(1, ((range.upperBound - range.lowerBound) / 10).rounded())
        return accessibilityElement(children: .ignore)
            .accessibilityLabel(surfaceDisplayName(control.name))
            .accessibilityValue("\(Int(value.wrappedValue))")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: set(value.wrappedValue + step)
                case .decrement: set(value.wrappedValue - step)
                @unknown default: break
                }
            }
    }
}

/// Clamp `raw` to the control's wire range, step it to an integer, and emit it
/// only on an actual step change so a slow drag never spams duplicate
/// messages — the shared emit path of the channel strip and the knob.
@MainActor
private func sendStepped(_ raw: Double,
                         control: ControlSurfaceDescriptor.Control,
                         model: BrainViewModel,
                         value: Binding<Double>) {
    let range = control.faderRange
    let stepped = min(max(raw, range.lowerBound), range.upperBound).rounded()
    guard stepped != value.wrappedValue else { return }
    value.wrappedValue = stepped
    model.sendSurface(control.msg, value: Int(stepped))
}

// MARK: - Channel strip (fader)

/// One mixer channel strip: LED value readout, a vertical long-throw fader
/// with scale ticks, and the control name as the scribble strip below.
private struct SurfaceChannelStrip: View {
    let control: ControlSurfaceDescriptor.Control
    let model: BrainViewModel
    @State private var value: Double

    private static let stripWidth: CGFloat = 64
    private static let faderHeight: CGFloat = 148
    private static let capSize = CGSize(width: 34, height: 16)

    init(control: ControlSurfaceDescriptor.Control, model: BrainViewModel) {
        self.control = control
        self.model = model
        _value = State(initialValue: control.faderRange.lowerBound)
    }

    var body: some View {
        VStack(spacing: 8) {
            LedReadout(text: "\(Int(value))")
                .frame(width: Self.stripWidth)
            fader
                .frame(width: Self.stripWidth, height: Self.faderHeight)
            ScribbleLabel(name: control.name, width: Self.stripWidth + 8)
        }
        .surfaceAdjustableAccessibility(control: control, value: $value) { set($0) }
    }

    private var fader: some View {
        GeometryReader { geo in
            let height = geo.size.height
            Canvas { ctx, size in
                let capH = Self.capSize.height
                let capW = Self.capSize.width
                let centerX = size.width / 2
                let travel = size.height - capH
                let range = control.faderRange
                let span = range.upperBound - range.lowerBound
                let t = span > 0 ? (value - range.lowerBound) / span : 0
                let capCenterY = capH / 2 + (1 - CGFloat(t)) * travel

                // Scale ticks — schematic, unlabeled (the readout shows the value).
                for i in 0...4 {
                    let y = capH / 2 + travel * CGFloat(i) / 4
                    var tick = Path()
                    tick.move(to: CGPoint(x: centerX - 16, y: y))
                    tick.addLine(to: CGPoint(x: centerX + 16, y: y))
                    ctx.stroke(tick, with: .color(Signalwave.grid), lineWidth: 1)
                }

                // Track slot.
                let track = CGRect(x: centerX - 2, y: capH / 2, width: 4, height: travel)
                ctx.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(Signalwave.bg))
                ctx.stroke(Path(roundedRect: track, cornerRadius: 2), with: .color(Signalwave.grid), lineWidth: 1)

                // Signal fill from the cap down to the bottom of the throw.
                let fillTop = min(capCenterY, capH / 2 + travel)
                let fill = CGRect(x: centerX - 2, y: fillTop,
                                  width: 4, height: capH / 2 + travel - fillTop)
                ctx.fill(Path(roundedRect: fill, cornerRadius: 2), with: .color(Signalwave.green))

                // Fader cap: charcoal block with the green index line.
                let cap = CGRect(x: centerX - capW / 2, y: capCenterY - capH / 2,
                                 width: capW, height: capH)
                ctx.fill(Path(roundedRect: cap, cornerRadius: 3), with: .color(Signalwave.bg))
                ctx.stroke(Path(roundedRect: cap, cornerRadius: 3), with: .color(Signalwave.dim), lineWidth: 1)
                var index = Path()
                index.move(to: CGPoint(x: cap.minX + 4, y: capCenterY))
                index.addLine(to: CGPoint(x: cap.maxX - 4, y: capCenterY))
                ctx.stroke(index, with: .color(Signalwave.green), lineWidth: 2)
            }
            .contentShape(Rectangle())
            // High priority so the enclosing ScrollView's pan cannot steal a
            // drag that starts on the fader.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        track(y: drag.location.y, height: height)
                    }
            )
        }
    }

    /// Map a touch position on the throw to a wire value.
    private func track(y: CGFloat, height: CGFloat) {
        let capH = Self.capSize.height
        let travel = max(1, height - capH)
        let t = 1 - min(max((y - capH / 2) / travel, 0), 1)
        let range = control.faderRange
        set(range.lowerBound + Double(t) * (range.upperBound - range.lowerBound))
    }

    private func set(_ raw: Double) {
        sendStepped(raw, control: control, model: model, value: $value)
    }
}

// MARK: - Potentiometer (knob)

/// A rotary potentiometer for non-level continuous controls: 270° throw from
/// 7:30 to 4:30, green value arc, charcoal cap with an index pointer. Vertical
/// drag anywhere on the knob adjusts it (the standard plugin-knob gesture).
private struct SurfaceKnob: View {
    let control: ControlSurfaceDescriptor.Control
    let model: BrainViewModel
    @State private var value: Double
    /// The value when the current drag started; nil while not dragging.
    @State private var dragAnchor: Double?

    private static let cellWidth: CGFloat = 78
    private static let knobSize: CGFloat = 52
    /// Points of vertical drag for a full sweep.
    private static let dragTravel: CGFloat = 140
    private static let startDeg = 135.0
    private static let sweepDeg = 270.0

    init(control: ControlSurfaceDescriptor.Control, model: BrainViewModel) {
        self.control = control
        self.model = model
        _value = State(initialValue: control.faderRange.lowerBound)
    }

    var body: some View {
        VStack(spacing: 6) {
            LedReadout(text: "\(Int(value))")
                .frame(width: Self.knobSize + 8)
            knob
                .frame(width: Self.knobSize, height: Self.knobSize)
            ScribbleLabel(name: control.name, width: Self.cellWidth)
        }
        .frame(width: Self.cellWidth)
        .surfaceAdjustableAccessibility(control: control, value: $value) { set($0) }
    }

    private var knob: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 2
            let range = control.faderRange
            let span = range.upperBound - range.lowerBound
            let t = span > 0 ? (value - range.lowerBound) / span : 0
            let pointerDeg = Self.startDeg + Self.sweepDeg * t

            // Throw track.
            var track = Path()
            track.addArc(center: center, radius: radius,
                         startAngle: .degrees(Self.startDeg),
                         endAngle: .degrees(Self.startDeg + Self.sweepDeg),
                         clockwise: false)
            ctx.stroke(track, with: .color(Signalwave.grid),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round))

            // Signal arc up to the current position.
            if t > 0.001 {
                var arc = Path()
                arc.addArc(center: center, radius: radius,
                           startAngle: .degrees(Self.startDeg),
                           endAngle: .degrees(pointerDeg),
                           clockwise: false)
                ctx.stroke(arc, with: .color(Signalwave.green),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }

            // Knob cap with the index pointer.
            let bodyRadius = radius - 6
            let body = CGRect(x: center.x - bodyRadius, y: center.y - bodyRadius,
                              width: bodyRadius * 2, height: bodyRadius * 2)
            ctx.fill(Path(ellipseIn: body), with: .color(Signalwave.bg))
            ctx.stroke(Path(ellipseIn: body), with: .color(Signalwave.dim), lineWidth: 1)

            let rad = pointerDeg * .pi / 180
            let dir = CGPoint(x: cos(rad), y: sin(rad))
            var pointer = Path()
            pointer.move(to: CGPoint(x: center.x + dir.x * bodyRadius * 0.35,
                                     y: center.y + dir.y * bodyRadius * 0.35))
            pointer.addLine(to: CGPoint(x: center.x + dir.x * bodyRadius * 0.9,
                                        y: center.y + dir.y * bodyRadius * 0.9))
            ctx.stroke(pointer, with: .color(Signalwave.green),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .contentShape(Circle())
        // High priority so the enclosing ScrollView's pan cannot steal the
        // vertical drag that turns the knob.
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if dragAnchor == nil { dragAnchor = value }
                    turn(from: dragAnchor ?? value, translation: drag.translation.height)
                }
                .onEnded { _ in dragAnchor = nil }
        )
    }

    /// Vertical relative drag: up increases.
    private func turn(from anchor: Double, translation: CGFloat) {
        let range = control.faderRange
        let span = range.upperBound - range.lowerBound
        set(anchor - Double(translation / Self.dragTravel) * span)
    }

    private func set(_ raw: Double) {
        sendStepped(raw, control: control, model: model, value: $value)
    }
}

// MARK: - Transport cluster

/// One transport-mapped control as a square icon button with the standard
/// glyph. Triggers/presets fire momentarily; the two-state transport toggle
/// latches and lights while engaged.
private struct SurfaceTransportButton: View {
    let control: ControlSurfaceDescriptor.Control
    let model: BrainViewModel
    @State private var engaged = false

    private var glyph: String { transportGlyph(control.name).icon }

    var body: some View {
        if control.widgetKind == .toggle, let states = control.toggleStates {
            Button {
                engaged.toggle()
                model.sendSurface(control.msg, value: (engaged ? states.on : states.off).value)
            } label: {
                label(caption: (engaged ? states.on : states.off).label)
                    .foregroundStyle(engaged ? Signalwave.bg : Signalwave.green)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(engaged ? Signalwave.green : Signalwave.bg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Signalwave.green.opacity(0.5), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        } else {
            Button {
                model.fireSurface(control)
            } label: {
                label(caption: shortCaption)
            }
            .buttonStyle(SurfacePadButtonStyle())
        }
    }

    private func label(caption: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: glyph)
                .font(.body.weight(.semibold))
            Text(caption)
                .font(Signalwave.mono(.caption2))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 6)
        .frame(width: 68, height: 54)
    }

    /// The caption under the glyph: the display name without the redundant
    /// "transport" prefix ("transport_rewind" → "rewind").
    private var shortCaption: String {
        let cleaned = surfaceDisplayName(control.name)
        let words = cleaned.split(separator: " ").filter { $0.lowercased() != "transport" }
        return words.isEmpty ? cleaned : words.joined(separator: " ")
    }
}

// MARK: - Console switch (mute / solo / rec)

/// A mixer channel switch: the big console letter (M/S/R) that lights solid
/// in its accent when engaged, with the channel name captioned below.
private struct SurfaceConsoleSwitch: View {
    let control: ControlSurfaceDescriptor.Control
    let model: BrainViewModel
    let letter: String
    let accent: Color
    @State private var engaged = false

    var body: some View {
        if let states = control.toggleStates {
            Button {
                engaged.toggle()
                model.sendSurface(control.msg, value: (engaged ? states.on : states.off).value)
            } label: {
                VStack(spacing: 4) {
                    Text(letter)
                        .font(Signalwave.mono(.title3, weight: .bold))
                        .foregroundStyle(engaged ? Signalwave.bg : accent)
                        .frame(width: 46, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(engaged ? accent : Signalwave.bg)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(engaged ? accent : Signalwave.grid, lineWidth: 1)
                        )
                    Text(channelCaption)
                        .font(Signalwave.mono(.caption2))
                        .foregroundStyle(Signalwave.dim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 56)
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// The channel the switch belongs to: the display name minus the function
    /// word ("moog mute" → "moog").
    private var channelCaption: String {
        let words = surfaceDisplayName(control.name).split(separator: " ").filter {
            !consoleSwitchWords.contains($0.lowercased())
        }
        return words.isEmpty ? surfaceDisplayName(control.name) : words.joined(separator: " ")
    }
}

// MARK: - LED toggle

/// A generic two-state switch with a status LED: lit green on the second
/// (engaged) value, dark on the first. `values` is daemon-ordered by wire
/// value, so index 0 is the "off"-like state the widget starts in (unsent —
/// the surface is write-only).
private struct SurfaceLedToggle: View {
    let control: ControlSurfaceDescriptor.Control
    let model: BrainViewModel
    @State private var engaged = false

    var body: some View {
        if let states = control.toggleStates {
            Button {
                engaged.toggle()
                model.sendSurface(control.msg, value: (engaged ? states.on : states.off).value)
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(engaged ? Signalwave.green : Signalwave.grid)
                        .frame(width: 7, height: 7)
                        .shadow(color: engaged ? Signalwave.green.opacity(0.8) : .clear, radius: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(surfaceDisplayName(control.name))
                            .font(Signalwave.mono(.caption, weight: .semibold))
                            .foregroundStyle(Signalwave.fg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text((engaged ? states.on : states.off).label)
                            .font(Signalwave.mono(.caption2))
                            .foregroundStyle(engaged ? Signalwave.green : Signalwave.dim)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Signalwave.bg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(engaged ? Signalwave.green.opacity(0.6) : Signalwave.grid, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Enum selector

/// A synth patch-style selector: prev / LED readout / next, cycling through
/// the control's named values. Handles any value-list length in fixed space
/// (unlike segmented controls), the rack idiom for program selection.
private struct SurfaceEnumSelector: View {
    let control: ControlSurfaceDescriptor.Control
    let model: BrainViewModel
    @State private var index = 0

    private var values: [ControlSurfaceDescriptor.NamedValue] { control.values ?? [] }

    var body: some View {
        HStack(spacing: 8) {
            Text(surfaceDisplayName(control.name))
                .font(Signalwave.mono(.caption))
                .foregroundStyle(Signalwave.fg)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            stepButton(systemImage: "chevron.left") { step(-1) }
            LedReadout(text: values[index].label, minWidth: 84)
            stepButton(systemImage: "chevron.right") { step(1) }
        }
    }

    private func stepButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Signalwave.green)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Signalwave.bg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Signalwave.grid, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    /// Cycle (wrapping, like a program dial) and send the newly dialed value.
    /// A single-value list has nothing to dial through, so don't re-send it.
    private func step(_ delta: Int) {
        let count = values.count
        guard count > 1 else { return }
        index = ((index + delta) % count + count) % count
        model.sendSurface(control.msg, value: values[index].value)
    }
}

// MARK: - Session switch button

/// One registered session in the cross-session switcher row; the daemon's
/// current session is lit solid. AUM reloading the session reloads this AU
/// too, so the fresh manifest (with the new `current`) arrives via fullState /
/// the re-push — no local highlight state to manage.
struct SessionSwitchButton: View {
    let session: ControlSurfaceDescriptor.Session
    let model: BrainViewModel

    var body: some View {
        Button {
            model.switchSession(session)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: session.isCurrent ? "rectangle.stack.fill" : "rectangle.stack")
                    .font(.caption)
                Text(session.name)
                    .font(Signalwave.mono(.caption2, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("pc \(session.program)")
                    .font(Signalwave.mono(.caption2))
                    .opacity(0.7)
            }
            .padding(.horizontal, 6)
            .frame(width: 92, height: 64)
            .foregroundStyle(session.isCurrent ? Signalwave.bg : Signalwave.green)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(session.isCurrent ? Signalwave.green : Signalwave.bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Signalwave.green.opacity(session.isCurrent ? 1 : 0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pads (trigger / preset)

/// A momentary pad for one-shot controls: dark at rest, fully lit while
/// pressed. Firing goes through `fireSurface` so noteOn triggers get their
/// deferred release.
private struct SurfacePad: View {
    let control: ControlSurfaceDescriptor.Control
    let model: BrainViewModel

    var body: some View {
        Button {
            model.fireSurface(control)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: control.widgetKind == .preset ? "square.stack" : "bolt.fill")
                    .font(.caption)
                Text(surfaceDisplayName(control.name))
                    .font(Signalwave.mono(.caption2, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 6)
            .frame(width: 84, height: 58)
        }
        .buttonStyle(SurfacePadButtonStyle())
    }
}

/// The pad's press behavior: green outline on charcoal at rest, solid green
/// with charcoal glyphs while held — a lit drum pad, no gloss.
private struct SurfacePadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Signalwave.bg : Signalwave.green)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(configuration.isPressed ? Signalwave.green : Signalwave.bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Signalwave.green.opacity(0.5), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
