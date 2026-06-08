import Foundation

// The "hands" command ring: the BrainController networking thread (decoding
// commands off the /midi-control WebSocket) is the PRODUCER, and the AUv3 render
// block (a realtime thread) is the CONSUMER, which drains commands and emits the
// bytes via the host midiOut block. This is the reverse direction from the audio
// tap, where the render thread produces.
//
// It is a thin alias over the generic SPSCRing; see SPSCRing for the lock-free
// contract (wait-free push/pop, drop-on-overflow).
public typealias MidiCommandRing = SPSCRing<MidiCommand>

public extension SPSCRing where Element == MidiCommand {
    /// A command ring of `capacity` slots, seeded with an inert command.
    convenience init(capacity: Int) {
        self.init(capacity: capacity, empty: MidiCommand(kind: .noteOff))
    }
}
