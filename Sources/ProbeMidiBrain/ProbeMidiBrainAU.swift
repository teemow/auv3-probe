import Foundation
import AVFoundation
import AudioToolbox
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
            emitCount: engine.statusEmitCount.load(ordering: .relaxed)
        )
    }

    // MARK: - Render resources

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        // Cache the host-provided realtime blocks for the render thread.
        engine.midiOut = midiOutputEventBlock
        engine.musicalContext = musicalContextBlock
        engine.transportState = transportStateBlock
        engine.reset()
        engine.setProgram(program)
    }

    public override func deallocateRenderResources() {
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
}
