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
    @Published var introspection: HostIntrospection?
    private var timer: Timer?

    init(audioUnit: ProbeMidiBrainAU) {
        self.audioUnit = audioUnit
        self.program = audioUnit.program
        self.status = audioUnit.status
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

    init(model: BrainViewModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                DaemonStatusView()
                statusPanel
                introspectionPanel
                observedPanel
#if DEBUG
                backdoorPanel
#endif
                sectionsPanel
                footswitchPanel
                outputPanel
            }
            .padding(16)
        }
        .background(Signalwave.bg.ignoresSafeArea())
        .tint(Signalwave.green)
        .preferredColorScheme(.dark)
        .onChange(of: model.program) { _ in model.commit() }
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

    private func endpointLabel(_ endpoint: HostIntrospection.CoreMIDISnapshot.Endpoint) -> String {
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
            Text(String(format: "%g", value.wrappedValue))
                .font(Signalwave.mono(.body))
                .foregroundStyle(Signalwave.fg)
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
            Text("\(value.wrappedValue)")
                .font(Signalwave.mono(.body))
                .foregroundStyle(Signalwave.fg)
            Stepper("", value: value, in: range)
                .labelsHidden()
                .tint(Signalwave.green)
        }
    }
}
