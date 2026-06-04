import Foundation
import AVFoundation
import AudioToolbox
import ProbeKit

// ProbeAudioTap — an `aufx` audio-effect AUv3 inserted in an AUM audio channel.
// It is a transparent passthrough that also taps the buffer and streams
// downsampled mono PCM + RMS/peak features over the LAN to mcp-midi-controller,
// giving an AI agent "ears" on the rig.
//
// Realtime work lives in TapDSP; networking lives in TapStreamer. This class is
// the AUAudioUnit shell: busses, config (stream host / decimation) persisted in
// fullState, and lifecycle wiring of the streamer.
@objc(ProbeAudioTapAU)
public final class ProbeAudioTapAU: AUAudioUnit {
    private let dsp = TapDSP()
    private var streamer: TapStreamer?

    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    public private(set) var config = TapConfig()

    private static let configStateKey = "probeAudioTapConfig"

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])

        dsp.decimation = config.decimation
    }

    // MARK: - Busses

    public override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    // MARK: - Config (UI API)

    /// Replace the config: persists, applies decimation, and (re)starts or stops
    /// the stream as needed.
    public func updateConfig(_ newConfig: TapConfig) {
        let hostChanged = newConfig.host != config.host
        let streamingChanged = newConfig.streaming != config.streaming
        config = newConfig
        dsp.decimation = max(1, newConfig.decimation)
        if streamingChanged || hostChanged {
            applyStreamingState()
        }
    }

    private func applyStreamingState() {
        if config.streaming, !config.host.isEmpty, streamer != nil {
            dsp.capturing.store(true, ordering: .relaxed)
            streamer?.start(host: config.host)
        } else {
            dsp.capturing.store(false, ordering: .relaxed)
            streamer?.stop()
        }
    }

    /// Status for the UI meter.
    public var levels: (peak: Float, rms: Float) { dsp.levels }
    public var isConnected: Bool { streamer?.connected.load(ordering: .relaxed) ?? false }

    // MARK: - Render resources

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let rate = outputBus.format.sampleRate
        streamer = TapStreamer(dsp: dsp, sampleRate: rate)
        dsp.decimation = max(1, config.decimation)
        dsp.prepare(maxFrames: Int(maximumFramesToRender))
        applyStreamingState()
    }

    public override func deallocateRenderResources() {
        streamer?.stop()
        streamer = nil
        dsp.capturing.store(false, ordering: .relaxed)
        dsp.teardown()
        super.deallocateRenderResources()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        dsp.makeRenderBlock()
    }

    // MARK: - State persistence (fullState)

    public override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            // The stream host is installation-specific; persisting it inside the
            // AUM session (on-device) is fine and never committed to git.
            if let data = try? JSONEncoder().encode(config) {
                state[Self.configStateKey] = data
            }
            return state
        }
        set {
            super.fullState = newValue
            if let data = newValue?[Self.configStateKey] as? Data,
               let decoded = try? JSONDecoder().decode(TapConfig.self, from: data) {
                updateConfig(decoded)
            }
        }
    }
}

/// Persisted configuration for ProbeAudioTap.
public struct TapConfig: Codable, Equatable {
    /// mcp-midi-controller `host[:port]` (LAN). Entered at runtime, never committed.
    public var host: String
    /// Whether the tap is actively streaming.
    public var streaming: Bool
    /// Integer downsample factor applied to the mono tap (1 = full rate).
    public var decimation: Int

    public init(host: String = "", streaming: Bool = false, decimation: Int = 4) {
        self.host = host
        self.streaming = streaming
        self.decimation = decimation
    }
}
