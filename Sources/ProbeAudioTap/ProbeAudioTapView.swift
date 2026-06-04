import SwiftUI
import Combine
import ProbeKit

// The control surface for ProbeAudioTap: stream target host, decimation, a
// start/stop toggle, a live level meter (peak/RMS), and connection status — in
// the signalwave language.

@MainActor
final class TapViewModel: ObservableObject {
    private let audioUnit: ProbeAudioTapAU
    @Published var config: TapConfig
    @Published var peak: Float = 0
    @Published var rms: Float = 0
    @Published var connected: Bool = false
    private var timer: Timer?

    init(audioUnit: ProbeAudioTapAU) {
        self.audioUnit = audioUnit
        self.config = audioUnit.config
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                let levels = self.audioUnit.levels
                self.peak = levels.peak
                self.rms = levels.rms
                self.connected = self.audioUnit.isConnected
            }
        }
    }

    deinit { timer?.invalidate() }

    func commit() { audioUnit.updateConfig(config) }
}

public struct ProbeAudioTapView: View {
    @ObservedObject var model: TapViewModel

    init(model: TapViewModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                meterPanel
                targetPanel
                streamPanel
            }
            .padding(16)
        }
        .background(Signalwave.bg.ignoresSafeArea())
        .tint(Signalwave.green)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            WaveGlyph().frame(width: 32, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("probe audio tap")
                    .font(Signalwave.mono(.headline, weight: .bold))
                    .foregroundStyle(Signalwave.fg)
                Text("// aufx · ears on the lan")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }
            Spacer()
        }
    }

    // MARK: - Meter

    private var meterPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("level")
            meterBar(label: "peak", value: model.peak)
            meterBar(label: "rms", value: model.rms)
        }
        .padding(12)
        .signalField()
    }

    private func meterBar(label: String, value: Float) -> some View {
        let clamped = CGFloat(max(0, min(1, value)))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(Signalwave.mono(.caption))
                    .foregroundStyle(Signalwave.dim)
                Spacer()
                Text(String(format: "%.3f", value))
                    .font(Signalwave.mono(.caption))
                    .foregroundStyle(Signalwave.fg)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Signalwave.grid)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(clamped > 0.9 ? Signalwave.amber : Signalwave.green)
                        .frame(width: geo.size.width * clamped)
                }
            }
            .frame(height: 8)
        }
    }

    // MARK: - Target

    private var targetPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("stream target")
            Text("// mcp-midi-controller host on your lan")
                .font(Signalwave.mono(.caption2))
                .foregroundStyle(Signalwave.dim)
            HStack(spacing: 8) {
                Text(">")
                    .font(Signalwave.mono(.body, weight: .bold))
                    .foregroundStyle(Signalwave.green)
                TextField("host:7800", text: $model.config.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(Signalwave.mono(.body))
                    .foregroundStyle(Signalwave.fg)
                    .tint(Signalwave.green)
                    .onSubmit { model.commit() }
            }
            .signalField()
            HStack(spacing: 8) {
                Text("decimation")
                    .font(Signalwave.mono(.caption))
                    .foregroundStyle(Signalwave.dim)
                Text("\(model.config.decimation)x")
                    .font(Signalwave.mono(.body))
                    .foregroundStyle(Signalwave.fg)
                Stepper("", value: $model.config.decimation, in: 1...32)
                    .labelsHidden()
                    .tint(Signalwave.green)
                    .onChange(of: model.config.decimation) { _ in model.commit() }
            }
        }
        .padding(12)
        .signalField()
    }

    // MARK: - Stream control

    private var streamPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader("stream")
                Spacer()
                Label(model.connected ? "connected" : "offline",
                      systemImage: model.connected ? "dot.radiowaves.left.and.right" : "wifi.slash")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(model.connected ? Signalwave.green : Signalwave.dim)
            }
            Button {
                model.config.streaming.toggle()
                model.commit()
            } label: {
                Text(model.config.streaming ? "stop streaming" : "start streaming")
            }
            .buttonStyle(.signalPrimary)
            .disabled(model.config.host.isEmpty)
        }
        .padding(12)
        .signalField()
    }
}
