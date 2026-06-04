import Foundation
import AVFoundation
import AudioToolbox
import os
import Atomics
import ProbeKit

// BrainEngine holds the realtime state for ProbeMidiBrain and produces the
// render block. It is deliberately a *separate* object from the AUAudioUnit so
// the render closure can capture it without forming a retain cycle with the AU
// (AU -> renderBlock -> engine; engine never references the AU).
//
// Realtime discipline:
//   - The authored program is published as a pre-sorted `RenderProgram` (no
//     sorting or array growth on the audio thread).
//   - The render thread reads it through `OSAllocatedUnfairLock.withLockIfAvailable`
//     (a non-blocking try-lock): if the UI thread is mid-edit, the render simply
//     skips evaluation for that cycle — harmless for MIDI, never blocks audio.
//   - Status the UI reads back (current section, last emitted scene, transport)
//     lives in atomics, so the UI never has to touch the realtime lock.
//
// See docs/auv3-extension.md for the full rationale.

/// A pre-sorted, render-friendly view of `BrainProgram` (parallel arrays, no
/// per-cycle sorting/allocation).
struct RenderProgram {
    var sectionStartBeats: [Double] = []
    var sectionScenes: [Int] = []
    var footswitches: [FootswitchMapping] = []
    var outputChannel: Int = 1
    var mode: SceneChangeMode = .programChange
    var sceneCC: Int = 0

    init() {}

    init(_ program: BrainProgram) {
        let ordered = program.orderedSections
        sectionStartBeats = ordered.map(\.startBeat)
        sectionScenes = ordered.map(\.scene)
        footswitches = program.footswitches
        outputChannel = program.outputChannel
        mode = program.sceneChangeMode
        sceneCC = program.sceneCC
    }

    /// Index of the section active at `beat`, or -1 before the first section.
    func sectionIndex(atBeat beat: Double) -> Int {
        var result = -1
        var i = 0
        while i < sectionStartBeats.count && sectionStartBeats[i] <= beat {
            result = i
            i += 1
        }
        return result
    }
}

final class BrainEngine: @unchecked Sendable {
    // Published program, read on the realtime thread via a non-blocking try-lock.
    private let program = OSAllocatedUnfairLock(initialState: RenderProgram())

    // Host-provided blocks, cached at allocateRenderResources time.
    var midiOut: AUMIDIOutputEventBlock?
    var musicalContext: AUHostMusicalContextBlock?
    var transportState: AUHostTransportStateBlock?

    // Render-thread-only carry-over (only the render thread mutates these).
    private var lastEmittedScene = -1
    private var lastSectionIndex = -1

    // Status mirrored for the UI (written on the render thread, read on main).
    let statusSection = ManagedAtomic<Int>(-1)
    let statusScene = ManagedAtomic<Int>(-1)
    let statusPlaying = ManagedAtomic<Bool>(false)
    /// Bumped every time a scene change is emitted, so the UI can flash activity.
    let statusEmitCount = ManagedAtomic<Int>(0)

    /// Publish a new program (called from the main/UI thread).
    func setProgram(_ newProgram: BrainProgram) {
        let render = RenderProgram(newProgram)
        program.withLock { $0 = render }
    }

    /// Reset the render-thread carry-over (e.g. on (re)allocation).
    func reset() {
        lastEmittedScene = -1
        lastSectionIndex = -1
        statusSection.store(-1, ordering: .relaxed)
        statusScene.store(-1, ordering: .relaxed)
        statusEmitCount.store(0, ordering: .relaxed)
    }

    // MARK: - Render

    func makeRenderBlock() -> AUInternalRenderBlock {
        return { [self]
            actionFlags, timestamp, frameCount, outputBusNumber, outputData, eventListHead, pullInputBlock in
            _ = actionFlags
            _ = frameCount
            _ = outputBusNumber
            _ = outputData
            _ = pullInputBlock

            // A MIDI processor produces no audio; clear any output buffers the
            // host pulled so nothing leaks if it is placed in an audio path.
            let ablPointer = UnsafeMutableAudioBufferListPointer(outputData)
            for buffer in ablPointer {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }

            // Snapshot the program out of the realtime lock with a non-blocking
            // try-lock. The snapshot only copies array *references* (a retain, no
            // element allocation); if the UI thread holds the lock we skip this
            // cycle — harmless for MIDI, never blocks audio. Processing then runs
            // outside the (@Sendable) lock closure so the event-list/timestamp
            // pointers are not captured across the Sendable boundary.
            guard let prog = self.program.withLockIfAvailable({ $0 }) else {
                return noErr
            }

            // 1) Footswitch input: walk the realtime event list.
            var event = eventListHead
            while let raw = event {
                let head = raw.pointee.head
                if head.eventType == .MIDI {
                    self.handleMIDI(raw.pointee.MIDI, program: prog, at: timestamp.pointee.mSampleTime)
                }
                event = UnsafePointer(head.next)
            }

            // 2) Transport-driven section boundaries.
            self.evaluateTransport(program: prog, at: timestamp.pointee.mSampleTime)

            return noErr
        }
    }

    // MARK: - MIDI in (footswitch)

    private func handleMIDI(_ midi: AUMIDIEvent, program prog: RenderProgram, at sampleTime: Double) {
        // AUMIDIEvent.data is a fixed 3-byte tuple; read only `length` bytes.
        let length = Int(midi.length)
        guard length >= 1 else { return }
        var bytes = midi.data
        let message = withUnsafePointer(to: &bytes.0) { ptr in
            MidiMessage.parse(ptr, count: min(length, 3))
        }
        guard let message = message else { return }

        for mapping in prog.footswitches where matches(mapping, message) {
            applyFootswitch(mapping.action, program: prog, at: sampleTime)
        }
    }

    private func matches(_ mapping: FootswitchMapping, _ message: MidiMessage) -> Bool {
        if mapping.channel != 0 && mapping.channel != message.channel { return false }
        switch mapping.kind {
        case .note:
            // Trigger on note-on only (ignore the matching note-off).
            return message.kind == .noteOn && message.number == mapping.number
        case .controlChange:
            // Trigger on a "pressed" CC (value >= 64), the footswitch convention.
            return message.kind == .controlChange && message.number == mapping.number && message.value >= 64
        case .programChange:
            return message.kind == .programChange && message.number == mapping.number
        }
    }

    private func applyFootswitch(_ action: SceneAction, program prog: RenderProgram, at sampleTime: Double) {
        let target: Int
        switch action {
        case .scene(let s):
            target = s
        case .next:
            let next = lastSectionIndex + 1
            guard next >= 0 && next < prog.sectionScenes.count else { return }
            lastSectionIndex = next
            target = prog.sectionScenes[next]
            statusSection.store(next, ordering: .relaxed)
        case .previous:
            let prev = lastSectionIndex - 1
            guard prev >= 0 && prev < prog.sectionScenes.count else { return }
            lastSectionIndex = prev
            target = prog.sectionScenes[prev]
            statusSection.store(prev, ordering: .relaxed)
        }
        emitScene(target, program: prog, at: sampleTime)
    }

    // MARK: - Transport

    private func evaluateTransport(program prog: RenderProgram, at sampleTime: Double) {
        guard let transportState = transportState else { return }
        var flags = AUHostTransportStateFlags(rawValue: 0)
        let haveTransport = transportState(&flags, nil, nil, nil)
        let moving = haveTransport && flags.contains(.moving)
        statusPlaying.store(moving, ordering: .relaxed)
        guard moving, let musicalContext = musicalContext else { return }

        var beat: Double = 0
        let haveContext = musicalContext(nil, nil, nil, &beat, nil, nil)
        guard haveContext else { return }

        let index = prog.sectionIndex(atBeat: beat)
        guard index >= 0, index != lastSectionIndex else {
            if index >= 0 { statusSection.store(index, ordering: .relaxed) }
            return
        }
        lastSectionIndex = index
        statusSection.store(index, ordering: .relaxed)
        emitScene(prog.sectionScenes[index], program: prog, at: sampleTime)
    }

    // MARK: - Emit

    private func emitScene(_ scene: Int, program prog: RenderProgram, at sampleTime: Double) {
        guard scene != lastEmittedScene, let midiOut = midiOut else {
            lastEmittedScene = scene
            return
        }
        lastEmittedScene = scene

        var out = (UInt8(0), UInt8(0), UInt8(0))
        let length: Int = withUnsafeMutablePointer(to: &out.0) { ptr in
            switch prog.mode {
            case .programChange:
                return MidiEncoder.programChange(channel: prog.outputChannel, program: scene, into: ptr)
            case .controlChange:
                return MidiEncoder.controlChange(channel: prog.outputChannel, cc: prog.sceneCC, value: scene, into: ptr)
            }
        }
        _ = withUnsafePointer(to: &out.0) { ptr in
            midiOut(AUEventSampleTime(sampleTime), 0, length, ptr)
        }
        statusScene.store(scene, ordering: .relaxed)
        statusEmitCount.wrappingIncrement(ordering: .relaxed)
    }
}
