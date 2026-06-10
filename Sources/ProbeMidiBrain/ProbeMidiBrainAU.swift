import Foundation
import AVFoundation
import AudioToolbox
import CoreMIDI
import os
import ProbeKit

// ProbeMidiBrain — an `aumi` MIDI-processor AUv3 that lives in an AUM MIDI strip.
// It receives MIDI (the "threefoot" footswitch, routed in by AUM) and, knowing
// the song structure, emits scene-change MIDI out (Program Change / CC) driven
// by the host transport position and by footswitch input.
//
// The realtime work lives in BrainEngine; this class is the AUAudioUnit shell:
// busses, MIDI-out declaration, transport/context wiring, and fullState
// persistence of the authored BrainProgram.
//
// @objc(...) pins a stable Objective-C class name so the extension's Info.plist
// can resolve it under SwiftPM's `Module.Class` mangling.
@objc(ProbeMidiBrainAU)
public final class ProbeMidiBrainAU: AUAudioUnit {
    private let engine = BrainEngine()
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    /// The authored program. Setting it republishes to the realtime engine.
    public private(set) var program: BrainProgram = .demo

    // The control plane (the LAN-command controller) is touched from the
    // render-resource thread (allocateRenderResources / deallocate), so it is
    // guarded by a non-realtime lock. The realtime render thread never touches
    // it — it only drains the engine's command ring (lock-free). The channel is
    // always-on: it auto-connects to the Bonjour-discovered daemon (the "hands"
    // only act when the agent actually sends commands), so there is no enable
    // flag — connection state is shown by the shared DaemonStatusView.
    private let control = OSAllocatedUnfairLock(initialState: ControlState())

    private struct ControlState {
        var controller: BrainController?
        // Host-diagnostics channel (reporter assembles + streamer ships over
        // /diagnostics). Created with render resources and torn down with them,
        // alongside the BrainController.
        var diagnostics: DiagnosticsChannel?
    }

    /// Key under which the program is stored inside `fullState`.
    private static let programStateKey = "probeMidiBrainProgram"

    /// Key under which the cached control-surface manifest is stored inside
    /// `fullState`, so AUM persists it with the session and the surface renders
    /// (and emits) even when the daemon is offline.
    private static let controlSurfaceStateKey = "probeMidiBrainControlSurface"

    // The cached control-surface manifest. Written from the BrainController's
    // socket queue (live push) and from the fullState setter (session load);
    // read by the UI poll and the fullState getter — hence the lock box, never
    // touched by the render thread.
    private let surfaceBox = OSAllocatedUnfairLockBox<ControlSurfaceDescriptor?>(nil)

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)

        // A MIDI processor carries no real audio, but a single output bus keeps
        // it placeable and gives the host a format to pull. Stereo float @ the
        // session rate is a safe default.
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let outputBus = try AUAudioUnitBus(format: format)
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        // No audio input — an empty array advertises "MIDI only". Created once and
        // stored (don't rebuild the bus array on every getter call).
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [])

        engine.setProgram(program)
    }

    // MARK: - Busses

    public override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    // MARK: - MIDI out

    public override var midiOutputNames: [String] {
        ["ProbeMidiBrain"]
    }

    // MARK: - MIDI protocol negotiation

    /// Advertise that this AU is happy to receive MIDI 2.0. The host reads this
    /// before allocating render resources; if it (AUM) supports MIDI 2.0 it then
    /// delivers inbound events as `AURenderEventMIDIEventList` (UMP) in this
    /// protocol, otherwise it falls back to legacy `AURenderEventMIDI`. The render
    /// block records which path/protocol AUM actually used (see BrainEngine's
    /// `observeUMP`), and the negotiated `hostMIDIProtocol`/`audioUnitMIDIProtocol`
    /// pair is captured off-thread by the diagnostics collector — together they
    /// reveal whether AUM is driving the node with MIDI 1.0 or 2.0.
    public override var audioUnitMIDIProtocol: MIDIProtocolID {
        ._2_0
    }

    // MARK: - Program (authoring API for the view model)

    /// Replace the program and republish it to the realtime engine.
    public func updateProgram(_ newProgram: BrainProgram) {
        program = newProgram
        engine.setProgram(newProgram)
    }

    // MARK: - Control surface (session-derived manifest + local emission)

    /// The cached control-surface manifest (nil until the daemon pushed one or
    /// AUM restored it from the session). Polled by the UI.
    public var controlSurface: ControlSurfaceDescriptor? {
        surfaceBox.value
    }

    /// Replace the cached manifest. Called from the BrainController callback
    /// (socket queue) and the fullState setter; AUM picks the new value up via
    /// the fullState getter on its next session save.
    public func updateControlSurface(_ surface: ControlSurfaceDescriptor?) {
        surfaceBox.value = surface
    }

    /// Enqueue one control-surface command for the render thread to emit via
    /// the host midiOut. Main-thread producer (the plugin UI) on its own SPSC
    /// ring — the LAN channel keeps `commandRing` to itself. Works without the
    /// daemon: this is the offline path of the surface.
    public func sendSurfaceCommand(_ command: MidiCommand) {
        // Overflow is dropped by the ring, same policy as the LAN channel.
        _ = engine.surfaceRing.push(command)
    }

    /// The engine's mirrored status, for the UI to poll.
    public var status: BrainStatus {
        BrainStatus(
            sectionIndex: engine.statusSection.load(ordering: .relaxed),
            scene: engine.statusScene.load(ordering: .relaxed),
            playing: engine.statusPlaying.load(ordering: .relaxed),
            emitCount: engine.statusEmitCount.load(ordering: .relaxed),
            commandCount: engine.statusCommandCount.load(ordering: .relaxed)
        )
    }

    // MARK: - Host introspection (control-surface analysis)

    /// The most recent host-diagnostics snapshot assembled by the view-independent
    /// `HostDiagnosticsReporter` (started with render resources). The UI reads this
    /// passively — capture is owned by the reporter, not the panel — so it is nil
    /// until render resources are allocated and the reporter has ticked once.
    public var latestDiagnostics: HostDiagnostics? {
        control.withLock { $0.diagnostics?.latest }
    }

    /// Force an immediate diagnostics capture for the panel's on-demand "dump"
    /// button. Routed through the reporter so the assembled snapshot also reaches
    /// the os_log fallback and any connected `/diagnostics` stream. Returns the
    /// fresh snapshot, or nil when the reporter is not running (render resources
    /// not yet allocated).
    @discardableResult
    public func captureIntrospection() -> HostDiagnostics? {
        control.withLock { $0.diagnostics?.capture() }
    }

    /// The accumulated observed-MIDI tally (drained from the render thread's ring
    /// off the render thread). Read by the UI; reset between experiments.
    public private(set) var observedSummary = ObservedMidiSummary()

    /// Drain every observed inbound MIDI event captured by the render thread into
    /// the running summary and return it. Called off the render thread (UI timer).
    @discardableResult
    public func pollObservedMIDI() -> ObservedMidiSummary {
        var event = ObservedMidiEvent()
        while engine.observedRing.pop(into: &event) {
            observedSummary.record(event)
        }
        return observedSummary
    }

    /// Reset the observed-MIDI tally (e.g. before a fresh experiment).
    public func resetObservedMIDI() {
        observedSummary = ObservedMidiSummary()
    }

#if DEBUG
    /// The dev-only CoreMIDI backdoor (enumerate destinations + direct CC send),
    /// for the "can the appex drive AUM outside the AU graph?" experiment.
    public let backdoor = MidiBackdoor()
#endif

    // MARK: - Render resources

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        // Cache the host-provided realtime blocks for the render thread.
        engine.midiOut = midiOutputEventBlock
        engine.musicalContext = musicalContextBlock
        engine.transportState = transportStateBlock
        engine.reset()
        engine.setProgram(program)
        // Create the LAN command channel client (sharing the engine's ring) and
        // start it — it auto-discovers the daemon and auto-reconnects.
        control.withLock { state in
            let controller = BrainController(ring: engine.commandRing)
            // Cache each pushed control-surface manifest (the lock box makes
            // the socket-queue write safe against UI/fullState readers).
            controller.onControlSurface = { [weak self] surface in
                self?.updateControlSurface(surface)
            }
            state.controller = controller
            controller.start()

            // Always-on diagnostics: assemble the host snapshot (reading the
            // engine's published render-thread readback) and stream it to the
            // daemon, independent of whether the plugin UI is open. BrainEngine
            // captures only transport + musical context on the render thread (no
            // render `AudioTimeStamp`), so `renderTime` stays unavailable here —
            // that field is populated by ProbeAudioTap, which reads it.
            let diagnostics = DiagnosticsChannel(source: "ProbeMidiBrain", audioUnit: self) { [engine] in
                let host = engine.hostSnapshot()
                return HostRenderSnapshot(transport: host.transport,
                                          musicalContext: host.musicalContext)
            }
            state.diagnostics = diagnostics
            diagnostics.start()
        }
    }

    public override func deallocateRenderResources() {
        control.withLock { state in
            state.controller?.stop()
            state.controller = nil
            state.diagnostics?.stop()
            state.diagnostics = nil
        }
        engine.midiOut = nil
        engine.musicalContext = nil
        engine.transportState = nil
        super.deallocateRenderResources()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        engine.makeRenderBlock()
    }

    // MARK: - State persistence (fullState)

    public override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            if let data = try? JSONEncoder().encode(program) {
                state[Self.programStateKey] = data
            }
            if let surface = surfaceBox.value,
               let data = try? JSONEncoder().encode(surface) {
                state[Self.controlSurfaceStateKey] = data
            }
            return state
        }
        set {
            super.fullState = newValue
            if let data = newValue?[Self.programStateKey] as? Data,
               let decoded = try? JSONDecoder().decode(BrainProgram.self, from: data) {
                updateProgram(decoded)
            }
            if let state = newValue {
                // A restored state without a surface key (or an undecodable one)
                // clears the cache: the surface is session-derived, so keeping
                // the previous session's controls would emit into the wrong rig.
                if let data = state[Self.controlSurfaceStateKey] as? Data,
                   let surface = try? JSONDecoder().decode(ControlSurfaceDescriptor.self, from: data) {
                    updateControlSurface(surface)
                } else {
                    updateControlSurface(nil)
                }
            }
        }
    }
}

/// A snapshot of the engine's realtime status, surfaced to the UI.
public struct BrainStatus: Equatable, Sendable {
    public var sectionIndex: Int
    public var scene: Int
    public var playing: Bool
    public var emitCount: Int
    public var commandCount: Int
}
