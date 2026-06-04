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
    private var timer: Timer?

    init(audioUnit: ProbeMidiBrainAU) {
        self.audioUnit = audioUnit
        self.program = audioUnit.program
        self.status = audioUnit.status
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in self.status = self.audioUnit.status }
        }
    }

    deinit { timer?.invalidate() }

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
                statusPanel
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
