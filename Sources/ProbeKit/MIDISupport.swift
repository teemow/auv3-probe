import Foundation

// Small, allocation-free MIDI helpers shared by the extensions. Building and
// classifying 1-3 byte MIDI 1.0 messages is pure integer math, safe to call
// from a realtime render block.

/// A classified incoming MIDI 1.0 channel-voice message (the subset the brain's
/// footswitch matcher cares about). Built from raw bytes with no allocation.
public struct MidiMessage: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case noteOn
        case noteOff
        case controlChange
        case programChange
        case other
    }

    public var kind: Kind
    /// 1-16.
    public var channel: Int
    /// Note number / CC number / program number (data1).
    public var number: Int
    /// Velocity / CC value (data2); 0 for program change.
    public var value: Int

    public init(kind: Kind, channel: Int, number: Int, value: Int) {
        self.kind = kind
        self.channel = channel
        self.number = number
        self.value = value
    }

    /// Parse the first message out of a raw MIDI byte buffer. Returns nil for
    /// system/realtime bytes or truncated data. Realtime-safe.
    public static func parse(_ bytes: UnsafePointer<UInt8>, count: Int) -> MidiMessage? {
        guard count >= 1 else { return nil }
        let status = bytes[0]
        guard status >= 0x80 else { return nil } // not a status byte
        let high = status & 0xF0
        let channel = Int(status & 0x0F) + 1
        switch high {
        case 0x90:
            guard count >= 3 else { return nil }
            let velocity = Int(bytes[2])
            // Note-on with velocity 0 is a note-off by convention.
            return MidiMessage(kind: velocity == 0 ? .noteOff : .noteOn,
                               channel: channel, number: Int(bytes[1]), value: velocity)
        case 0x80:
            guard count >= 3 else { return nil }
            return MidiMessage(kind: .noteOff, channel: channel, number: Int(bytes[1]), value: Int(bytes[2]))
        case 0xB0:
            guard count >= 3 else { return nil }
            return MidiMessage(kind: .controlChange, channel: channel, number: Int(bytes[1]), value: Int(bytes[2]))
        case 0xC0:
            guard count >= 2 else { return nil }
            return MidiMessage(kind: .programChange, channel: channel, number: Int(bytes[1]), value: 0)
        default:
            return MidiMessage(kind: .other, channel: channel, number: 0, value: 0)
        }
    }
}

/// Build raw MIDI 1.0 bytes for the messages the brain emits. Each returns the
/// number of bytes written into `out` (a caller-provided 3-byte buffer), so the
/// render block never allocates.
public enum MidiEncoder {
    /// Program Change. `channel` is 1-16; clamped program to 0-127.
    @discardableResult
    public static func programChange(channel: Int, program: Int, into out: UnsafeMutablePointer<UInt8>) -> Int {
        let ch = UInt8((max(1, min(16, channel)) - 1) & 0x0F)
        out[0] = 0xC0 | ch
        out[1] = UInt8(max(0, min(127, program)))
        return 2
    }

    /// Control Change. `channel` is 1-16; cc/value clamped to 0-127.
    @discardableResult
    public static func controlChange(channel: Int, cc: Int, value: Int, into out: UnsafeMutablePointer<UInt8>) -> Int {
        let ch = UInt8((max(1, min(16, channel)) - 1) & 0x0F)
        out[0] = 0xB0 | ch
        out[1] = UInt8(max(0, min(127, cc)))
        out[2] = UInt8(max(0, min(127, value)))
        return 3
    }

    /// Note On. `channel` is 1-16; note/velocity clamped to 0-127.
    @discardableResult
    public static func noteOn(channel: Int, note: Int, velocity: Int, into out: UnsafeMutablePointer<UInt8>) -> Int {
        let ch = UInt8((max(1, min(16, channel)) - 1) & 0x0F)
        out[0] = 0x90 | ch
        out[1] = UInt8(max(0, min(127, note)))
        out[2] = UInt8(max(0, min(127, velocity)))
        return 3
    }

    /// Note Off. `channel` is 1-16; note/velocity clamped to 0-127.
    @discardableResult
    public static func noteOff(channel: Int, note: Int, velocity: Int, into out: UnsafeMutablePointer<UInt8>) -> Int {
        let ch = UInt8((max(1, min(16, channel)) - 1) & 0x0F)
        out[0] = 0x80 | ch
        out[1] = UInt8(max(0, min(127, note)))
        out[2] = UInt8(max(0, min(127, velocity)))
        return 3
    }

    /// System realtime transport byte (Start 0xFA, Continue 0xFB, Stop 0xFC).
    /// A single status byte with no data bytes.
    @discardableResult
    public static func transport(_ kind: TransportKind, into out: UnsafeMutablePointer<UInt8>) -> Int {
        out[0] = kind.statusByte
        return 1
    }
}

/// The three MIDI system-realtime transport messages the brain can emit.
public enum TransportKind: UInt8, Sendable {
    case start
    case stop
    case `continue`

    /// The MIDI 1.0 system-realtime status byte.
    public var statusByte: UInt8 {
        switch self {
        case .start: return 0xFA
        case .continue: return 0xFB
        case .stop: return 0xFC
        }
    }
}

/// A single MIDI command pushed from the daemon to the brain (the agent's
/// "hands"). Decoded off the networking thread into a fixed-size value type,
/// enqueued on a lock-free ring, and emitted from the realtime render block.
/// All fields are stored as bytes so the struct is trivially copyable with no
/// retains on the audio thread.
public struct MidiCommand: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case noteOn
        case noteOff
        case controlChange
        case programChange
        case transportStart
        case transportStop
        case transportContinue
    }

    public var kind: Kind
    /// 1-16 (ignored for transport kinds).
    public var channel: UInt8
    /// note / cc number / program (data1).
    public var data1: UInt8
    /// velocity / cc value (data2); 0 where unused.
    public var data2: UInt8

    public init(kind: Kind, channel: UInt8 = 1, data1: UInt8 = 0, data2: UInt8 = 0) {
        self.kind = kind
        self.channel = channel
        self.data1 = data1
        self.data2 = data2
    }
}
