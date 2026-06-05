import Foundation
import AVFoundation
import AudioToolbox
import os
import ProbeKit

// ProbeAudioTap — an `aufx` audio-effect AUv3 inserted in an AUM audio channel.
// It is a transparent passthrough that also taps the buffer and streams
// downsampled mono PCM + RMS/peak features over the LAN to mcp-midi-controller,
// giving an AI agent "ears" on the rig.
//
// Realtime work lives in TapDSP; networking lives in TapStreamer. This class is
// the AUAudioUnit shell: busses, config (streaming flag) persisted in
// fullState, and lifecycle wiring of the streamer.
@objc(ProbeAudioTapAU)
public final class ProbeAudioTapAU: AUAudioUnit {
    private let dsp = TapDSP()

    // The control plane (config + streamer) is touched from the main/UI thread
    // (updateConfig), the render-resource thread (allocateRenderResources), and
    // fullState set (any thread), so it is guarded by a non-realtime lock. The
    // realtime render thread never touches it — it only uses `dsp` (atomics).
    private let control = OSAllocatedUnfairLock(initialState: ControlState())

    private struct ControlState {
        var config = TapConfig()
        var streamer: TapStreamer?
    }

    private var outputBus: AUAudioUnitBus!
    // Created once and stored — recreating an AUAudioUnitBusArray on every getter
    // call is wasteful and can confuse hosts that cache the array.
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    private static let configStateKey = "probeAudioTapConfig"

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
    }

    // MARK: - Busses

    public override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    /// Current config (snapshot).
    public var config: TapConfig { control.withLock { $0.config } }

    // MARK: - Config (UI API)

    /// Replace the config: persists and (re)starts or stops the stream as needed.
    public func updateConfig(_ newConfig: TapConfig) {
        control.withLock { state in
            state.config = newConfig
            applyStreamingStateLocked(&state)
        }
    }

    /// Apply the streaming on/off state. Must be called with `control` held.
    /// The host comes from Bonjour discovery (DaemonDiscovery), so the streamer
    /// finds the daemon itself and auto-reconnects.
    private func applyStreamingStateLocked(_ state: inout ControlState) {
        if state.config.streaming, let streamer = state.streamer {
            dsp.capturing.store(true, ordering: .relaxed)
            streamer.start()
        } else {
            dsp.capturing.store(false, ordering: .relaxed)
            state.streamer?.stop()
        }
    }

    /// Status for the UI meter.
    public var levels: (peak: Float, rms: Float) { dsp.levels }

    // MARK: - Render resources

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let rate = outputBus.format.sampleRate
        let channels = Int(outputBus.format.channelCount)
        dsp.prepare(maxFrames: Int(maximumFramesToRender), channels: channels)
        control.withLock { state in
            state.streamer = TapStreamer(dsp: dsp, sampleRate: rate, channels: channels)
            applyStreamingStateLocked(&state)
        }
    }

    public override func deallocateRenderResources() {
        control.withLock { state in
            state.streamer?.stop()
            state.streamer = nil
        }
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
            // Persist the tap's config (streaming flag + decimation) inside the
            // AUM session, per node. The daemon host is not stored here — it is
            // found via Bonjour discovery (DaemonDiscovery).
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
///
/// The host is not stored here — the daemon is found via Bonjour discovery
/// (DaemonDiscovery). Only the streaming flag is per-node `fullState`. (A `host`
/// or legacy `decimation` left over in an older session's JSON is simply ignored
/// on decode.)
public struct TapConfig: Codable, Equatable {
    /// Whether the tap is actively streaming.
    public var streaming: Bool

    public init(streaming: Bool = false) {
        self.streaming = streaming
    }
}
