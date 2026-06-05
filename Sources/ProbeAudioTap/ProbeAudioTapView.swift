import SwiftUI
import Combine
import ProbeKit

// The control surface for ProbeAudioTap: a start/stop toggle, a live level
// meter (peak/RMS), and connection status — in the signalwave language. Audio is
// streamed full-rate and full-fidelity (interleaved, no decimation), so there is
// no quality knob to tune.

@MainActor
final class TapViewModel: ObservableObject {
    private let audioUnit: ProbeAudioTapAU
    @Published var config: TapConfig
    @Published var peak: Float = 0
    @Published var rms: Float = 0
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
                DaemonStatusView()
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
            SectionHeader("stream options")
            Text("// streams to the auto-discovered daemon")
                .font(Signalwave.mono(.caption2))
                .foregroundStyle(Signalwave.dim)
            Text("// full-rate · interleaved · native channels")
                .font(Signalwave.mono(.caption2))
                .foregroundStyle(Signalwave.dim)
        }
        .padding(12)
        .signalField()
    }

    // MARK: - Stream control

    private var streamPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("stream")
            Button {
                model.config.streaming.toggle()
                model.commit()
            } label: {
                Text(model.config.streaming ? "stop streaming" : "start streaming")
            }
            .buttonStyle(.signalPrimary)
        }
        .padding(12)
        .signalField()
    }
}
