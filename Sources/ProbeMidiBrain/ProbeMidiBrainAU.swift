import Foundation
import AVFoundation
import AudioToolbox
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
    }

    /// Key under which the program is stored inside `fullState`.
    private static let programStateKey = "probeMidiBrainProgram"

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

    // MARK: - Program (authoring API for the view model)

    /// Replace the program and republish it to the realtime engine.
    public func updateProgram(_ newProgram: BrainProgram) {
        program = newProgram
        engine.setProgram(newProgram)
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

    /// Assemble a full host-introspection snapshot: the sanctioned readback the
    /// render thread captured (transport + musical context + render config),
    /// merged with the backdoor surfaces (AVAudioSession + CoreMIDI) read here off
    /// the render thread. Logs it under `com.teemow.auv3probe` (so it streams to
    /// idevicesyslog) and returns it for the on-device panel.
    public func captureIntrospection() -> HostIntrospection {
        let host = engine.hostSnapshot()
        var snapshot = HostIntrospection()
        snapshot.transport = host.transport
        snapshot.musicalContext = host.musicalContext
        snapshot.audioSession = HostIntrospectionCollector.audioSession()
        snapshot.coreMIDI = HostIntrospectionCollector.coreMIDI()

        var render = HostIntrospection.Render()
        render.maximumFramesToRender = Int(maximumFramesToRender)
        render.midiOutputNames = midiOutputNames
        render.outputBusFormats = (0..<outputBusses.count).map { index in
            let format = outputBusses[index].format
            return "\(Int(format.sampleRate))Hz ch\(format.channelCount)"
        }
        snapshot.render = render

        snapshot.log()
        observedSummary.log()
        return snapshot
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
            state.controller = controller
            controller.start()
        }
    }

    public override func deallocateRenderResources() {
        control.withLock { state in
            state.controller?.stop()
            state.controller = nil
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
            return state
        }
        set {
            super.fullState = newValue
            if let data = newValue?[Self.programStateKey] as? Data,
               let decoded = try? JSONDecoder().decode(BrainProgram.self, from: data) {
                updateProgram(decoded)
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
