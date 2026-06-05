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

    // Lock-free command ring: the BrainController networking thread pushes
    // MIDI commands decoded off the /midi-control WebSocket (the agent's
    // "hands"); the render thread drains and emits them via midiOut. Sized for a
    // generous burst of agent-driven commands; overflow is dropped by the ring.
    let commandRing = MidiCommandRing(capacity: 256)

    // Lock-free observed-MIDI ring: the render thread pushes EVERY inbound event
    // (channel voice, system-realtime, sysex leaders) for the host control-
    // surface analysis; a UI/report thread drains it to tally what AUM delivers.
    // Sized to absorb a burst of clock (24 ppqn) plus notes between UI drains.
    let observedRing = ObservedMidiRing(capacity: 1024)

    // Latest sanctioned host readback (transport + musical context), captured on
    // the render thread and read by the introspection report off the render
    // thread. Written via a non-blocking try-lock so the render thread never
    // blocks on the UI/report reader.
    private struct HostState {
        var transport = HostIntrospection.Transport()
        var musicalContext = HostIntrospection.MusicalContext()
    }
    private let hostState = OSAllocatedUnfairLock(initialState: HostState())

    // Render-thread-only carry-over (only the render thread mutates these).
    private var lastEmittedScene = -1
    private var lastSectionIndex = -1
    // Transport/context carried from captureHostState to evaluateTransport so the
    // host blocks are read exactly once per cycle.
    private var lastMoving = false
    private var lastHaveContext = false
    private var lastBeat: Double = 0
    // Scratch command reused while draining the ring (no per-cycle allocation).
    private var scratchCommand = MidiCommand(kind: .noteOff)

    // Status mirrored for the UI (written on the render thread, read on main).
    let statusSection = ManagedAtomic<Int>(-1)
    let statusScene = ManagedAtomic<Int>(-1)
    let statusPlaying = ManagedAtomic<Bool>(false)
    /// Bumped every time a scene change is emitted, so the UI can flash activity.
    let statusEmitCount = ManagedAtomic<Int>(0)
    /// Bumped every time a command from the LAN channel is emitted.
    let statusCommandCount = ManagedAtomic<Int>(0)

    /// Publish a new program (called from the main/UI thread).
    func setProgram(_ newProgram: BrainProgram) {
        let render = RenderProgram(newProgram)
        program.withLock { $0 = render }
    }

    /// Reset the render-thread carry-over (e.g. on (re)allocation).
    func reset() {
        lastEmittedScene = -1
        lastSectionIndex = -1
        lastMoving = false
        lastHaveContext = false
        lastBeat = 0
        statusSection.store(-1, ordering: .relaxed)
        statusScene.store(-1, ordering: .relaxed)
        statusEmitCount.store(0, ordering: .relaxed)
        statusCommandCount.store(0, ordering: .relaxed)
        hostState.withLock { $0 = HostState() }
    }

    /// The latest sanctioned host readback, for the introspection report. Read
    /// off the render thread (UI/report timer); the render thread writes it via a
    /// non-blocking try-lock.
    func hostSnapshot() -> (transport: HostIntrospection.Transport,
                            musicalContext: HostIntrospection.MusicalContext) {
        hostState.withLock { ($0.transport, $0.musicalContext) }
    }

    // MARK: - Render

    /// Non-Sendable render-block pointers, wrapped so the `@Sendable`
    /// `withLockIfAvailable` closure can carry them without a warning. Only ever
    /// used synchronously on the realtime thread inside the try-lock.
    private struct RenderInputs: @unchecked Sendable {
        let events: UnsafePointer<AURenderEvent>?
        let sampleTime: Double
    }

    func makeRenderBlock() -> AUInternalRenderBlock {
        return { [self]
            actionFlags, timestamp, frameCount, outputBusNumber, outputData, eventListHead, pullInputBlock in
            _ = actionFlags
            _ = frameCount
            _ = outputBusNumber
            _ = pullInputBlock

            // A MIDI processor produces no audio; clear any output buffers the
            // host pulled so nothing leaks if it is placed in an audio path.
            let ablPointer = UnsafeMutableAudioBufferListPointer(outputData)
            for buffer in ablPointer {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }

            let sampleTime = timestamp.pointee.mSampleTime

            // 0) Drain the LAN command ring (the agent's "hands") and emit each
            // command via midiOut at the current sample time. This is realtime-
            // safe: the ring pop is wait-free/allocation-free and does not touch
            // the program lock, so direct agent commands flow even while the UI
            // is mid-edit. midiOut is only ever called here (the render thread).
            self.drainCommands(at: sampleTime)

            // 1) Capture the sanctioned host readback (transport + musical
            // context) into the introspection snapshot, every cycle, independent
            // of the program lock. Also publishes statusPlaying and the
            // carry-over evaluateTransport consumes (so the host blocks are read
            // exactly once per cycle).
            self.captureHostState()

            // 2) Evaluate footswitch input + section boundaries under a
            // non-blocking try-lock. If the UI thread is mid-edit we skip
            // evaluation this cycle (harmless for MIDI, never blocks audio). All
            // work happens *inside* the closure so the program is never copied
            // out (no array retains on the audio thread); arrays are read by
            // index. handleMIDI also records every inbound event into the
            // observed-MIDI ring.
            let inputs = RenderInputs(events: eventListHead, sampleTime: sampleTime)
            let evaluated: Bool? = self.program.withLockIfAvailable { prog in
                var event = inputs.events
                while let raw = event {
                    let head = raw.pointee.head
                    if head.eventType == .MIDI {
                        self.handleMIDI(raw.pointee.MIDI, program: &prog, at: inputs.sampleTime)
                    }
                    event = UnsafePointer(head.next)
                }
                self.evaluateTransport(program: &prog, at: inputs.sampleTime)
                return true
            }

            // 3) If the program lock was unavailable (UI mid-edit) we skipped the
            // walk above — but the analysis must still see EVERY inbound event, so
            // capture them here without touching the program.
            if evaluated == nil {
                var event = inputs.events
                while let raw = event {
                    let head = raw.pointee.head
                    if head.eventType == .MIDI {
                        self.observe(raw.pointee.MIDI, at: inputs.sampleTime)
                    }
                    event = UnsafePointer(head.next)
                }
            }

            return noErr
        }
    }

    // MARK: - LAN command channel (the "hands")

    /// Drain every queued LAN command and emit it via midiOut. Realtime-safe:
    /// pops are wait-free, the byte building uses a stack tuple (no allocation),
    /// and midiOut is the host-provided realtime block. Called only on the
    /// render thread.
    private func drainCommands(at sampleTime: Double) {
        guard let midiOut = midiOut else {
            // No output block yet: drain and discard so the ring cannot back up.
            while commandRing.pop(into: &scratchCommand) {}
            return
        }
        var emitted = 0
        while commandRing.pop(into: &scratchCommand) {
            let cmd = scratchCommand
            var out = (UInt8(0), UInt8(0), UInt8(0))
            let length: Int = withUnsafeMutablePointer(to: &out.0) { ptr in
                switch cmd.kind {
                case .noteOn:
                    return MidiEncoder.noteOn(channel: Int(cmd.channel), note: Int(cmd.data1), velocity: Int(cmd.data2), into: ptr)
                case .noteOff:
                    return MidiEncoder.noteOff(channel: Int(cmd.channel), note: Int(cmd.data1), velocity: Int(cmd.data2), into: ptr)
                case .controlChange:
                    return MidiEncoder.controlChange(channel: Int(cmd.channel), cc: Int(cmd.data1), value: Int(cmd.data2), into: ptr)
                case .programChange:
                    return MidiEncoder.programChange(channel: Int(cmd.channel), program: Int(cmd.data1), into: ptr)
                case .transportStart:
                    return MidiEncoder.transport(.start, into: ptr)
                case .transportStop:
                    return MidiEncoder.transport(.stop, into: ptr)
                case .transportContinue:
                    return MidiEncoder.transport(.continue, into: ptr)
                }
            }
            _ = withUnsafePointer(to: &out.0) { ptr in
                midiOut(AUEventSampleTime(sampleTime), 0, length, ptr)
            }
            emitted += 1
        }
        if emitted > 0 {
            statusCommandCount.wrappingIncrement(by: emitted, ordering: .relaxed)
        }
    }

    // MARK: - MIDI in (capture + footswitch)

    /// Record one inbound event into the observed-MIDI ring. Captures EVERYTHING
    /// (channel voice, system-realtime, sysex leaders) so the analysis can
    /// characterise AUM's delivery — not just the messages the footswitch matcher
    /// reacts to. Wait-free and allocation-free (the ring drops on overflow).
    private func observe(_ midi: AUMIDIEvent, at sampleTime: Double) {
        let data = midi.data
        observedRing.push(ObservedMidiEvent(
            sampleTime: sampleTime,
            length: midi.length,
            cable: midi.cable,
            byte0: data.0, byte1: data.1, byte2: data.2
        ))
    }

    private func handleMIDI(_ midi: AUMIDIEvent, program prog: inout RenderProgram, at sampleTime: Double) {
        // Capture every inbound event first (incl. clock/transport/sysex that the
        // footswitch matcher below ignores) for the host control-surface analysis.
        observe(midi, at: sampleTime)

        // AUMIDIEvent.data is a fixed 3-byte tuple; read only `length` bytes.
        let length = Int(midi.length)
        guard length >= 1 else { return }
        var bytes = midi.data
        let message = withUnsafePointer(to: &bytes.0) { ptr in
            MidiMessage.parse(ptr, count: min(length, 3))
        }
        guard let message = message else { return }

        // Iterate by index so the footswitch array's buffer is read in place and
        // never retained on the audio thread (FootswitchMapping is a value type).
        var i = 0
        while i < prog.footswitches.count {
            let mapping = prog.footswitches[i]
            if matches(mapping, message) {
                applyFootswitch(mapping.action, program: &prog, at: sampleTime)
            }
            i += 1
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

    private func applyFootswitch(_ action: SceneAction, program prog: inout RenderProgram, at sampleTime: Double) {
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
        emitScene(target, program: &prog, at: sampleTime)
    }

    // MARK: - Host introspection capture

    /// Read the sanctioned host blocks once per cycle and publish: (a) the full
    /// transport + musical-context snapshot for the introspection report, (b)
    /// statusPlaying for the UI, (c) the carry-over evaluateTransport consumes.
    /// Called on the render thread, outside the program lock.
    private func captureHostState() {
        var transport = HostIntrospection.Transport()
        if let transportState = transportState {
            var flags = AUHostTransportStateFlags(rawValue: 0)
            var samplePosition: Double = 0
            var cycleStart: Double = 0
            var cycleEnd: Double = 0
            if transportState(&flags, &samplePosition, &cycleStart, &cycleEnd) {
                transport.available = true
                transport.moving = flags.contains(.moving)
                transport.recording = flags.contains(.recording)
                transport.cycling = flags.contains(.cycling)
                transport.samplePosition = samplePosition
                transport.cycleStartBeat = cycleStart
                transport.cycleEndBeat = cycleEnd
            }
        }

        var context = HostIntrospection.MusicalContext()
        if let musicalContext = musicalContext {
            var tempo: Double = 0
            var tsNumerator: Double = 0
            var tsDenominator: Int = 0
            var beat: Double = 0
            var sampleOffset: Int = 0
            var downbeat: Double = 0
            if musicalContext(&tempo, &tsNumerator, &tsDenominator, &beat, &sampleOffset, &downbeat) {
                context.available = true
                context.tempo = tempo
                context.timeSignatureNumerator = tsNumerator
                context.timeSignatureDenominator = tsDenominator
                context.currentBeatPosition = beat
                context.sampleOffsetToNextBeat = sampleOffset
                context.currentMeasureDownbeatPosition = downbeat
            }
        }

        // Carry-over for evaluateTransport (render-thread-only).
        lastMoving = transport.moving
        lastHaveContext = context.available
        lastBeat = context.currentBeatPosition
        statusPlaying.store(transport.moving, ordering: .relaxed)

        // Publish the snapshot for the report; skip if the reader holds the lock.
        // Capture immutable copies so the @Sendable lock closure carries value
        // types (avoids capturing the mutable locals built above).
        let transportSnapshot = transport
        let contextSnapshot = context
        hostState.withLockIfAvailable { state in
            state.transport = transportSnapshot
            state.musicalContext = contextSnapshot
        }
    }

    // MARK: - Transport

    private func evaluateTransport(program prog: inout RenderProgram, at sampleTime: Double) {
        // Consume the readback captured by captureHostState this cycle.
        guard lastMoving, lastHaveContext else { return }

        let index = prog.sectionIndex(atBeat: lastBeat)
        guard index >= 0, index != lastSectionIndex else {
            if index >= 0 { statusSection.store(index, ordering: .relaxed) }
            return
        }
        lastSectionIndex = index
        statusSection.store(index, ordering: .relaxed)
        emitScene(prog.sectionScenes[index], program: &prog, at: sampleTime)
    }

    // MARK: - Emit

    private func emitScene(_ scene: Int, program prog: inout RenderProgram, at sampleTime: Double) {
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
