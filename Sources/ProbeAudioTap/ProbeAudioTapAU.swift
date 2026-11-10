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
// the AUAudioUnit shell: busses, config (streaming flag and name) persisted in
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
        // Host-diagnostics channel (reporter assembles + streamer ships over
        // /diagnostics). Created with render resources and torn down with them,
        // like the audio streamer above.
        var diagnostics: DiagnosticsChannel?
    }

    private var outputBus: AUAudioUnitBus!
    // Created once and stored — recreating an AUAudioUnitBusArray on every getter
    // call is wasteful and can confuse hosts that cache the array.
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

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

    /// Current config (snapshot), as last set in the UI or restored by the
    /// host. The UI polls it so an open window follows a restore.
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
    /// finds the daemon itself and auto-reconnects. The stream is opened under
    /// the config's name, so a restore that brings one makes the tap dial
    /// again as that name.
    private func applyStreamingStateLocked(_ state: inout ControlState) {
        if state.config.streaming, let streamer = state.streamer {
            dsp.capturing.store(true, ordering: .relaxed)
            streamer.start(name: state.config.streamName)
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
        // Cache the host blocks so the render thread can capture the sanctioned
        // transport + musical-context + render-timestamp readback for the
        // diagnostics reporter (the tap reads the same host surface BrainEngine does).
        dsp.transportState = transportStateBlock
        dsp.musicalContext = musicalContextBlock
        control.withLock { state in
            state.streamer = TapStreamer(dsp: dsp, sampleRate: rate, channels: channels)
            applyStreamingStateLocked(&state)

            // Always-on diagnostics: assemble the host snapshot (reading dsp's
            // published render-thread readback) and stream it to the daemon,
            // independent of whether audio is being tapped.
            let diagnostics = DiagnosticsChannel(source: "ProbeAudioTap", audioUnit: self) { [dsp] in
                dsp.renderSnapshot()
            }
            state.diagnostics = diagnostics
            diagnostics.start()
        }
    }

    public override func deallocateRenderResources() {
        control.withLock { state in
            state.streamer?.stop()
            state.streamer = nil
            state.diagnostics?.stop()
            state.diagnostics = nil
        }
        dsp.capturing.store(false, ordering: .relaxed)
        dsp.transportState = nil
        dsp.musicalContext = nil
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
            // Persist the tap's config (streaming flag + name) inside the AUM
            // session, per node. The daemon host is not stored here — it is
            // found via Bonjour discovery (DaemonDiscovery).
            if let data = config.fullStateData {
                state[TapConfig.fullStateKey] = data
            }
            return state
        }
        set {
            super.fullState = newValue
            // A state without a config (or with one that does not decode)
            // leaves the current config in place.
            if let restored = TapConfig.restored(fromFullState: newValue) {
                updateConfig(restored)
            }
        }
    }
}

/// Persisted configuration for ProbeAudioTap.
///
/// The host is not stored here — the daemon is found via Bonjour discovery
/// (DaemonDiscovery). The streaming flag and the name are per-node `fullState`.
/// (A `host` or legacy `decimation` left over in an older session's JSON is
/// simply ignored on decode, and a session from before taps had names decodes
/// to a tap without one.)
public struct TapConfig: Codable, Equatable {
    /// Whether the tap is actively streaming.
    public var streaming: Bool

    /// What the tap calls itself when it dials the daemon, nil for a tap
    /// without a name. The daemon writes it into the sessions it authors (the
    /// session and the strip the tap sits on), and by it tells the streams of
    /// a session's taps apart.
    public var name: String?

    public init(streaming: Bool = true, name: String? = nil) {
        self.streaming = streaming
        self.name = name
    }

    /// The name as the tap sends it: without surrounding whitespace, and nil
    /// when nothing is left.
    public var streamName: String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - fullState (how a host stores the config in its session)

    /// Key under which the config sits inside the AU's `fullState`: JSON bytes,
    /// which AUM keeps in the node's `AuStateDoc`. The daemon authors the same
    /// key into the sessions it writes, so keep the two in sync.
    public static let fullStateKey = "probeAudioTapConfig"

    /// The config a host handed back in `fullState`, or nil when the state
    /// carries none or one that does not decode.
    public static func restored(fromFullState state: [String: Any]?) -> TapConfig? {
        guard let data = state?[fullStateKey] as? Data else { return nil }
        return try? JSONDecoder().decode(TapConfig.self, from: data)
    }

    /// The config as stored under `fullStateKey`.
    public var fullStateData: Data? {
        try? JSONEncoder().encode(self)
    }
}
