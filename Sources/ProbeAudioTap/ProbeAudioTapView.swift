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
    /// The config on screen. A change goes to the audio unit at once, so this
    /// copy differs from `audioUnit.config` only after the host restored a
    /// state, which `poll` then adopts.
    @Published var config: TapConfig {
        didSet {
            guard !adoptingRestoredConfig, config != oldValue else { return }
            audioUnit.updateConfig(config)
        }
    }
    /// Set while `poll` takes over the audio unit's config, so that is not
    /// written back as if it were a change made here.
    private var adoptingRestoredConfig = false
    @Published var peak: Float = 0
    @Published var rms: Float = 0
    private var timer: Timer?

    init(audioUnit: ProbeAudioTapAU) {
        self.audioUnit = audioUnit
        self.config = audioUnit.config
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in self.poll() }
        }
    }

    deinit { timer?.invalidate() }

    /// Mirror the audio unit's state (timer-driven; internal for the tests).
    func poll() {
        let levels = audioUnit.levels
        peak = levels.peak
        rms = levels.rms
        // The host restores the config whenever it likes. AUM does it after
        // creating the unit, and iOS may have built this view by then: without
        // this, the button keeps showing the streaming state the unit started
        // with.
        let restored = audioUnit.config
        if restored != config {
            adoptingRestoredConfig = true
            config = restored
            adoptingRestoredConfig = false
        }
    }
}

public struct ProbeAudioTapView: View {
    @ObservedObject var model: TapViewModel

    init(model: TapViewModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                DaemonStatusView()
                meterPanel
                streamPanel
            }
            .padding(10)
        }
        .background(Signalwave.bg.ignoresSafeArea())
        .tint(Signalwave.green)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            WaveGlyph().frame(width: 24, height: 15)
            VStack(alignment: .leading, spacing: 1) {
                Text("probe audio tap")
                    .font(Signalwave.mono(.subheadline, weight: .bold))
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
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("level")
            meterBar(label: "peak", value: model.peak)
            meterBar(label: "rms", value: model.rms)
        }
        .padding(8)
        .signalField()
    }

    private func meterBar(label: String, value: Float) -> some View {
        let clamped = CGFloat(max(0, min(1, value)))
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
                Spacer()
                Text(String(format: "%.3f", value))
                    .font(Signalwave.mono(.caption2))
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
            .frame(height: 6)
        }
    }

    // MARK: - Stream control

    private var streamPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("stream")
            Button {
                // Reaches the audio unit through `config`'s didSet.
                model.config.streaming.toggle()
            } label: {
                Text(model.config.streaming ? "stop streaming" : "start streaming")
            }
            .buttonStyle(.signalPrimary)
            Text("// full-rate · interleaved · native channels → auto-discovered daemon")
                .font(Signalwave.mono(.caption2))
                .foregroundStyle(Signalwave.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .signalField()
    }
}
