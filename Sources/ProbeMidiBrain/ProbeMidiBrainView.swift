import SwiftUI
import Combine
import ProbeKit

// The authoring surface for ProbeMidiBrain, in the signalwave language. Edits a
// BrainProgram (song sections + footswitch map + output encoding) and shows the
// engine's live status (current section / last emitted scene / transport).

@MainActor
final class BrainViewModel: ObservableObject {
    private let audioUnit: ProbeMidiBrainAU
    @Published var program: BrainProgram
    @Published var status: BrainStatus
    /// Rolling tally of every inbound MIDI event AUM routes into the node.
    @Published var observed = ObservedMidiSummary()
    /// The latest host-diagnostics snapshot, mirrored passively from the AU's
    /// view-independent `HostDiagnosticsReporter`. The panel no longer drives
    /// capture (which used to die whenever the UI closed) — it just reflects the
    /// reporter's `latest` on each poll tick.
    @Published var introspection: HostDiagnostics?
    /// The cached session control surface (daemon-pushed or restored from the
    /// AUM session via fullState). Mirrored on each poll tick; nil until a
    /// session has been imported.
    @Published var surface: ControlSurfaceDescriptor?
    private var timer: Timer?

    init(audioUnit: ProbeMidiBrainAU) {
        self.audioUnit = audioUnit
        self.program = audioUnit.program
        self.status = audioUnit.status
        self.surface = audioUnit.controlSurface
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in self.poll() }
        }
        poll()
    }

    deinit { timer?.invalidate() }

    private func poll() {
        status = audioUnit.status
        observed = audioUnit.pollObservedMIDI()
        introspection = audioUnit.latestDiagnostics
        // Only publish on actual change — the surface arrives rarely (session
        // import / load) and republishing every tick would rebuild the panel.
        let latest = audioUnit.controlSurface
        if latest != surface { surface = latest }
    }

    // MARK: - Control surface (local emission, no daemon round-trip)

    /// Emit one control-surface message with the given wire value. Pushes onto
    /// the engine's surface ring; the render thread drains and emits it via the
    /// host midiOut — works with the daemon offline.
    func sendSurface(_ msg: ControlSurfaceDescriptor.Msg, value: Int) {
        guard let cmd = msg.command(value: value) else { return }
        audioUnit.sendSurfaceCommand(cmd)
    }

    /// Fire a one-shot control (trigger/preset): emit its fire value and, for
    /// noteOn messages, the matching release so no note hangs. The release is
    /// deferred — back-to-back on/off would land in the same render cycle as a
    /// zero-length note many receivers ignore. asyncAfter keeps the main thread
    /// as the surface ring's single producer (the ring is SPSC).
    func fireSurface(_ control: ControlSurfaceDescriptor.Control) {
        sendSurface(control.msg, value: control.fireValue)
        if let release = control.msg.releaseCommand {
            let audioUnit = audioUnit
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
                audioUnit.sendSurfaceCommand(release)
            }
        }
    }

    /// Fire the reporter's on-demand capture (the UI's "dump" button) and mirror
    /// the fresh snapshot. A no-op for the view if the reporter is not yet running.
    func captureIntrospection() {
        if let snapshot = audioUnit.captureIntrospection() {
            introspection = snapshot
        }
    }

    /// Reset the observed-MIDI tally (e.g. before a fresh experiment).
    func resetObserved() {
        audioUnit.resetObservedMIDI()
        observed = audioUnit.pollObservedMIDI()
    }

    /// Push the current program into the realtime engine.
    func commit() { audioUnit.updateProgram(program) }

    func addSection() {
        let nextBeat = (program.sections.map(\.startBeat).max() ?? -4) + 4
        let nextScene = (program.sections.map(\.scene).max() ?? -1) + 1
        program.sections.append(SongSection(name: "section \(program.sections.count + 1)",
                                             startBeat: max(0, nextBeat), scene: max(0, nextScene)))
        commit()
    }

    func removeSection(_ id: UUID) {
        program.sections.removeAll { $0.id == id }
        commit()
    }

    func addFootswitch() {
        program.footswitches.append(FootswitchMapping(kind: .controlChange, number: 64, channel: 0, action: .next))
        commit()
    }

    func removeFootswitch(_ id: UUID) {
        program.footswitches.removeAll { $0.id == id }
        commit()
    }

#if DEBUG
    // Dev-only CoreMIDI backdoor experiment state.
    @Published var backdoorDestinations: [MidiBackdoor.Destination] = []
    @Published var backdoorSelection: Int?
    @Published var backdoorChannel = 1
    @Published var backdoorCC = 17
    @Published var backdoorValue = 64
    @Published var backdoorResult = ""

    func refreshBackdoorDestinations() {
        backdoorDestinations = audioUnit.backdoor.destinations()
        if backdoorSelection == nil || !backdoorDestinations.contains(where: { $0.id == backdoorSelection }) {
            backdoorSelection = backdoorDestinations.first?.id
        }
    }

    func sendBackdoorCC() {
        guard let id = backdoorSelection,
              let destination = backdoorDestinations.first(where: { $0.id == id }) else {
            backdoorResult = "no destination selected"
            return
        }
        backdoorResult = audioUnit.backdoor.sendCC(to: destination,
                                                   channel: backdoorChannel,
                                                   cc: backdoorCC,
                                                   value: backdoorValue)
    }
#endif
}

public struct ProbeMidiBrainView: View {
    @ObservedObject var model: BrainViewModel

    /// Diagnostics (host introspection / observed MIDI / dev backdoor) are
    /// monitoring, not authoring — collapsed by default and parked below the
    /// editable panels so the things you actually tune are at the top.
    @State private var showDiagnostics = false

    /// The session control surface is the performance panel — expanded by
    /// default (its per-device groups collapse individually).
    @State private var showControlSurface = true

    init(model: BrainViewModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                DaemonStatusView()
                statusPanel
                controlSurfaceSection
                sectionsPanel
                footswitchPanel
                outputPanel
                diagnosticsSection
            }
            .padding(16)
        }
        .background(Signalwave.bg.ignoresSafeArea())
        .tint(Signalwave.green)
        .preferredColorScheme(.dark)
        .onChange(of: model.program) { _ in model.commit() }
    }

    // MARK: - Diagnostics (collapsible, monitoring only)

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { showDiagnostics.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showDiagnostics ? "chevron.down" : "chevron.right")
                    SectionHeader("diagnostics")
                    Spacer()
                    Text(showDiagnostics ? "hide" : "show")
                        .font(Signalwave.mono(.caption2))
                        .foregroundStyle(Signalwave.dim)
                }
            }
            .buttonStyle(.plain)

            if showDiagnostics {
                introspectionPanel
                observedPanel
#if DEBUG
                backdoorPanel
#endif
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            WaveGlyph().frame(width: 32, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("probe midi brain")
                    .font(Signalwave.mono(.headline, weight: .bold))
                    .foregroundStyle(Signalwave.fg)
                Text("// aumi · scene driver")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }
            Spacer()
        }
    }

    // MARK: - Status

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("status")
            HStack(spacing: 8) {
                chip(model.status.playing ? "transport: playing" : "transport: stopped",
                     color: model.status.playing ? Signalwave.green : Signalwave.dim)
                chip("section: \(label(forSection: model.status.sectionIndex))")
                chip("scene: \(model.status.scene < 0 ? "-" : String(model.status.scene))")
                chip("commands: \(model.status.commandCount)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .signalField()
    }

    private func label(forSection index: Int) -> String {
        let ordered = model.program.orderedSections
        guard index >= 0 && index < ordered.count else { return "-" }
        return ordered[index].name
    }

    // MARK: - Control surface (session rig, emits locally via the engine ring)

    private var controlSurfaceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { showControlSurface.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showControlSurface ? "chevron.down" : "chevron.right")
                    SectionHeader("control surface")
                    Spacer()
                    if let surface = model.surface {
                        Text(surfaceLabel(surface))
                            .font(Signalwave.mono(.caption2))
                            .foregroundStyle(Signalwave.dim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .buttonStyle(.plain)

            if showControlSurface {
                if let surface = model.surface {
                    // .id on the descriptor (content, not just the session name)
                    // resets per-device expansion + widget state whenever the
                    // surface changes — including a re-import of the same
                    // session with different mappings.
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(surface.devices.enumerated()), id: \.offset) { item in
                            SurfaceDeviceGroup(device: item.element,
                                               expandedInitially: surface.devices.count == 1,
                                               model: model)
                        }
                    }
                    .id(surface)
                } else {
                    Text("no surface yet — import an AUM session on the daemon")
                        .font(Signalwave.mono(.caption2))
                        .foregroundStyle(Signalwave.dim)
                }
            }
        }
    }

    private func surfaceLabel(_ surface: ControlSurfaceDescriptor) -> String {
        var name = surface.session
        if let title = surface.title, !title.isEmpty { name = title }
        return "\(name) · \(surface.devices.count) device\(surface.devices.count == 1 ? "" : "s")"
    }

    // MARK: - Host introspection (control-surface readback)

    private var introspectionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader("host introspection")
                Spacer()
                Button { model.captureIntrospection() } label: { Label("dump", systemImage: "doc.text.magnifyingglass") }
                    .buttonStyle(.signalGhost)
            }
            if let snapshot = model.introspection {
                let transport = snapshot.transport
                let context = snapshot.musicalContext
                let session = snapshot.audioSession
                WrapLayout(spacing: 6, lineSpacing: 4) {
                    SignalChip(text: transport.available ? (transport.moving ? "transport: moving" : "transport: stopped") : "transport: n/a",
                               color: transport.available ? Signalwave.green : Signalwave.dim)
                    if transport.recording { SignalChip(text: "recording", color: Signalwave.amber) }
                    if transport.cycling { SignalChip(text: "cycling") }
                    SignalChip(text: context.available ? "tempo: \(String(format: "%.1f", context.tempo))" : "tempo: n/a",
                               color: context.available ? Signalwave.green : Signalwave.dim)
                    SignalChip(text: "sig: \(String(format: "%g", context.timeSignatureNumerator))/\(context.timeSignatureDenominator)")
                    SignalChip(text: "beat: \(String(format: "%.2f", context.currentBeatPosition))")
                    SignalChip(text: "rate: \(Int(session.sampleRate))hz")
                    SignalChip(text: "buf: \(Int((session.ioBufferDuration * session.sampleRate).rounded()))")
                    SignalChip(text: session.isOtherAudioPlaying ? "other-audio: yes" : "other-audio: no",
                               color: session.isOtherAudioPlaying ? Signalwave.amber : Signalwave.dim)
                    SignalChip(text: "midi-out: \(snapshot.render.midiOutputNames.joined(separator: ","))")
                }
                introspectionDetail(title: "audio route in", items: session.inputPorts)
                introspectionDetail(title: "audio route out", items: session.outputPorts)
                introspectionDetail(title: "coremidi sources (\(snapshot.coreMIDI.sources.count))",
                                    items: snapshot.coreMIDI.sources.map(endpointLabel))
                introspectionDetail(title: "coremidi destinations (\(snapshot.coreMIDI.destinations.count))",
                                    items: snapshot.coreMIDI.destinations.map(endpointLabel))
            } else {
                Text("capturing…")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .signalField()
    }

    private func endpointLabel(_ endpoint: HostDiagnostics.CoreMIDISnapshot.Endpoint) -> String {
        let primary = endpoint.displayName.isEmpty ? endpoint.name : endpoint.displayName
        return endpoint.device.isEmpty ? primary : "\(endpoint.device) · \(primary)"
    }

    @ViewBuilder
    private func introspectionDetail(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Signalwave.mono(.caption2, weight: .semibold))
                .foregroundStyle(Signalwave.dim)
            if items.isEmpty {
                Text("—")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            } else {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(Signalwave.mono(.caption2))
                        .foregroundStyle(Signalwave.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Observed MIDI (what AUM delivers)

    private var observedPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader("observed midi in")
                Spacer()
                Button { model.resetObserved() } label: { Label("reset", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.signalGhost)
            }
            let observed = model.observed
            WrapLayout(spacing: 6, lineSpacing: 4) {
                SignalChip(text: "total: \(observed.total)")
                SignalChip(text: "note on: \(observed.noteOn)")
                SignalChip(text: "note off: \(observed.noteOff)")
                SignalChip(text: "cc: \(observed.controlChange)")
                SignalChip(text: "pc: \(observed.programChange)")
                SignalChip(text: "pitch: \(observed.pitchBend)")
                SignalChip(text: "clock: \(observed.clock)", color: observed.clock > 0 ? Signalwave.green : Signalwave.dim)
                SignalChip(text: "start/stop/cont: \(observed.start)/\(observed.stop)/\(observed.continue)")
                SignalChip(text: "sysex: \(observed.sysex)", color: observed.sysex > 0 ? Signalwave.amber : Signalwave.dim)
                SignalChip(text: "ump: \(observed.ump)", color: observed.ump > 0 ? Signalwave.green : Signalwave.dim)
                SignalChip(text: "param: \(observed.parameter)/\(observed.parameterRamp)", color: (observed.parameter + observed.parameterRamp) > 0 ? Signalwave.amber : Signalwave.dim)
                SignalChip(text: "other: \(observed.other)")
            }
            HStack(spacing: 8) {
                chip("channels: \(observed.channels.isEmpty ? "-" : observed.channels.map(String.init).joined(separator: ","))")
                chip("last: \(observed.lastMessage.isEmpty ? "-" : observed.lastMessage)")
            }
            if observed.ump > 0 {
                HStack(spacing: 8) {
                    chip("ump mt: \(observed.umpMessageTypes.isEmpty ? "-" : observed.umpMessageTypes.map(String.init).joined(separator: ","))")
                    chip("ump proto: \(observed.umpProtocols.isEmpty ? "-" : observed.umpProtocols.joined(separator: ","))")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .signalField()
    }

#if DEBUG
    // MARK: - CoreMIDI backdoor (dev-only)

    private var backdoorPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader("coremidi backdoor · dev")
                Spacer()
                Button { model.refreshBackdoorDestinations() } label: { Label("scan", systemImage: "antenna.radiowaves.left.and.right") }
                    .buttonStyle(.signalGhost)
            }
            if model.backdoorDestinations.isEmpty {
                Text("scan to enumerate coremidi destinations")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            } else {
                Picker("destination", selection: $model.backdoorSelection) {
                    ForEach(model.backdoorDestinations) { destination in
                        Text(destination.label).tag(Optional(destination.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(Signalwave.green)
                HStack(spacing: 14) {
                    intStepperField(label: "ch", value: $model.backdoorChannel, range: 1...16)
                    intStepperField(label: "cc", value: $model.backdoorCC, range: 0...127)
                    intStepperField(label: "val", value: $model.backdoorValue, range: 0...127)
                }
                Button { model.sendBackdoorCC() } label: { Label("send cc direct", systemImage: "paperplane") }
                    .buttonStyle(.signalGhost(Signalwave.amber))
            }
            if !model.backdoorResult.isEmpty {
                Text(model.backdoorResult)
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.fg)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .signalField()
    }
#endif

    // MARK: - Sections

    private var sectionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader("song sections")
                Spacer()
                Button { model.addSection() } label: { Label("add", systemImage: "plus") }
                    .buttonStyle(.signalGhost)
            }
            if model.program.sections.isEmpty {
                Text("no sections — the brain only reacts to footswitches")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }
            ForEach($model.program.sections) { $section in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("name", text: $section.name)
                            .font(Signalwave.mono(.body))
                            .foregroundStyle(Signalwave.fg)
                        Button { model.removeSection(section.id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.signalGhost(Signalwave.amber))
                    }
                    HStack(spacing: 14) {
                        stepperField(label: "beat", value: $section.startBeat, step: 1, range: 0...100_000)
                        intStepperField(label: "scene", value: $section.scene, range: 0...127)
                    }
                }
                .padding(12)
                .signalField()
            }
        }
    }

    // MARK: - Footswitches

    private var footswitchPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader("footswitch map")
                Spacer()
                Button { model.addFootswitch() } label: { Label("add", systemImage: "plus") }
                    .buttonStyle(.signalGhost)
            }
            ForEach($model.program.footswitches) { $mapping in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("kind", selection: $mapping.kind) {
                            Text("note").tag(TriggerKind.note)
                            Text("cc").tag(TriggerKind.controlChange)
                            Text("pc").tag(TriggerKind.programChange)
                        }
                        .pickerStyle(.menu)
                        .tint(Signalwave.green)
                        Spacer()
                        Button { model.removeFootswitch(mapping.id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.signalGhost(Signalwave.amber))
                    }
                    HStack(spacing: 14) {
                        intStepperField(label: "number", value: $mapping.number, range: 0...127)
                        intStepperField(label: "channel", value: $mapping.channel, range: 0...16)
                    }
                    actionPicker(for: $mapping)
                }
                .padding(12)
                .signalField()
            }
        }
    }

    private func actionPicker(for mapping: Binding<FootswitchMapping>) -> some View {
        let kindBinding = Binding<Int>(
            get: {
                switch mapping.wrappedValue.action {
                case .next: return 0
                case .previous: return 1
                case .scene: return 2
                }
            },
            set: { newValue in
                switch newValue {
                case 0: mapping.wrappedValue.action = .next
                case 1: mapping.wrappedValue.action = .previous
                default: mapping.wrappedValue.action = .scene(0)
                }
            }
        )
        return VStack(alignment: .leading, spacing: 6) {
            Picker("action", selection: kindBinding) {
                Text("next").tag(0)
                Text("previous").tag(1)
                Text("scene").tag(2)
            }
            .pickerStyle(.segmented)
            if case .scene(let scene) = mapping.wrappedValue.action {
                let sceneBinding = Binding<Int>(
                    get: { scene },
                    set: { mapping.wrappedValue.action = .scene($0) }
                )
                intStepperField(label: "scene", value: sceneBinding, range: 0...127)
            }
        }
    }

    // MARK: - Output

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("scene-change output")
            intStepperField(label: "midi channel", value: $model.program.outputChannel, range: 1...16)
            Picker("mode", selection: $model.program.sceneChangeMode) {
                Text("program change").tag(SceneChangeMode.programChange)
                Text("control change").tag(SceneChangeMode.controlChange)
            }
            .pickerStyle(.segmented)
            if model.program.sceneChangeMode == .controlChange {
                intStepperField(label: "cc number", value: $model.program.sceneCC, range: 0...127)
            }
        }
        .padding(12)
        .signalField()
    }

    // MARK: - Field helpers

    private func chip(_ text: String, color: Color = Signalwave.green) -> some View {
        SignalChip(text: text, color: color)
    }

    private func stepperField(label: String, value: Binding<Double>, step: Double, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Signalwave.mono(.caption))
                .foregroundStyle(Signalwave.dim)
            // Direct numeric entry — wide ranges like beat (0…100000) are
            // impractical to reach by tapping a stepper.
            TextField("", value: clamped(value, to: range), format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(Signalwave.mono(.body))
                .foregroundStyle(Signalwave.fg)
                .tint(Signalwave.green)
                .frame(maxWidth: 96)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .tint(Signalwave.green)
        }
    }

    private func intStepperField(label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Signalwave.mono(.caption))
                .foregroundStyle(Signalwave.dim)
            TextField("", value: clamped(value, to: range), format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(Signalwave.mono(.body))
                .foregroundStyle(Signalwave.fg)
                .tint(Signalwave.green)
                .frame(maxWidth: 72)
            Stepper("", value: value, in: range)
                .labelsHidden()
                .tint(Signalwave.green)
        }
    }

    // MARK: - Clamping bindings (typed values stay within the valid range)

    private func clamped(_ binding: Binding<Double>, to range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )
    }

    private func clamped(_ binding: Binding<Int>, to range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}

// MARK: - Control-surface widgets

/// One session-derived device: a collapsible group of its controls. Expansion
/// is per-group local state (reset when a new session's surface arrives via the
/// parent's `.id`).
private struct SurfaceDeviceGroup: View {
    let device: ControlSurfaceDescriptor.Device
    let model: BrainViewModel
    @State private var expanded: Bool

    init(device: ControlSurfaceDescriptor.Device, expandedInitially: Bool, model: BrainViewModel) {
        self.device = device
        self.model = model
        _expanded = State(initialValue: expandedInitially)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
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
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(Array(device.controls.enumerated()), id: \.offset) { item in
                    SurfaceControlRow(control: item.element, model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .signalField()
    }
}

/// One renderable control, dispatched on its widget kind. Widget state (fader
/// position, picked value) is local — AUM gives no feedback path, so the
/// surface is write-only and the state just remembers the last sent value.
private struct SurfaceControlRow: View {
    let control: ControlSurfaceDescriptor.Control
    let model: BrainViewModel
    @State private var faderValue: Double
    @State private var selection: Int

    init(control: ControlSurfaceDescriptor.Control, model: BrainViewModel) {
        self.control = control
        self.model = model
        _faderValue = State(initialValue: control.faderRange.lowerBound)
        _selection = State(initialValue: control.values?.first?.value ?? 0)
    }

    var body: some View {
        switch control.widgetKind {
        case .fader:
            fader
        case .toggle, .picker:
            valuePicker
        case .trigger, .preset:
            Button { model.fireSurface(control) } label: {
                Label(control.name,
                      systemImage: control.widgetKind == .preset ? "square.stack" : "bolt")
            }
            .buttonStyle(.signalGhost)
        case nil:
            // A widget kind from a newer daemon: name it, don't render it.
            HStack(spacing: 6) {
                name
                Text("(\(control.widget) — unsupported)")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }
        }
    }

    private var name: some View {
        Text(control.name)
            .font(Signalwave.mono(.caption))
            .foregroundStyle(Signalwave.fg)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var fader: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                name
                Spacer()
                Text("\(Int(faderValue))")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }
            Slider(value: $faderValue, in: control.faderRange, step: 1)
                .tint(Signalwave.green)
                .onChange(of: faderValue) { newValue in
                    model.sendSurface(control.msg, value: Int(newValue))
                }
        }
    }

    /// toggle (two named states) and enum (pick-one) share the picker: segmented
    /// while the labels fit, menu for long enums.
    ///
    /// The surface is write-only (AUM gives no feedback path), so `selection`
    /// starts on the first value without sending it — and since Picker only
    /// fires onChange on an actual change, sending the first value requires
    /// selecting another one first. Accepted: the alternative (a "send" button
    /// per picker) costs more space than the edge case is worth.
    private var valuePicker: some View {
        let values = control.values ?? []
        return VStack(alignment: .leading, spacing: 4) {
            name
            if values.count <= 3 {
                Picker(control.name, selection: $selection) {
                    ForEach(values, id: \.value) { value in
                        Text(value.label).tag(value.value)
                    }
                }
                .pickerStyle(.segmented)
            } else {
                Picker(control.name, selection: $selection) {
                    ForEach(values, id: \.value) { value in
                        Text(value.label).tag(value.value)
                    }
                }
                .pickerStyle(.menu)
                .tint(Signalwave.green)
            }
        }
        .onChange(of: selection) { newValue in
            model.sendSurface(control.msg, value: newValue)
        }
    }
}
