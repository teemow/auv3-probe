import Foundation
import os

// Observed-MIDI capture: the "characterise what AUM actually delivers" side of
// the control-surface analysis. Unlike the footswitch matcher (which only cares
// about the few channel-voice messages it maps), this records EVERYTHING the
// render block sees inbound — channel voice, system-realtime (clock / start /
// stop / continue), and sysex leaders — so we can measure AUM's MIDI routing:
// which channel routed MIDI arrives on, whether AUM sends clock/transport into
// the node, and whether sysex passes through.
//
// Same SPSC lock-free contract as MidiCommandRing, but the DIRECTION matches the
// audio tap: the render thread is the PRODUCER (pushes each inbound event), and
// a UI/report thread is the CONSUMER (drains for display + os_log). Pushing is
// wait-free and allocation-free; on overflow the oldest is dropped by the ring.

/// One captured inbound render event, as the AUv3 render block sees it. A
/// trivially copyable value type (no retains on the audio thread). It carries
/// three flavours, discriminated by `wire`:
///   - `.legacy`  — an `AUMIDIEvent`: at most three inline bytes (`byte0…2`);
///     `length` is the host-reported byte count, which can exceed 3 (a sysex
///     leader) even though only the first three bytes are kept.
///   - `.ump`     — one packet of an `AUMIDIEventList` (Universal MIDI Packet):
///     the first two 32-bit `word0`/`word1` are kept (enough to classify the
///     message type, group, and channel-voice status); `length` is the packet's
///     word count and `umpProtocol` is the negotiated list protocol.
///   - `.parameter` / `.parameterRamp` — an `AUParameterEvent`: the host driving
///     this AU's parameters via automation (`parameterAddress` + `value`).
public struct ObservedMidiEvent: Equatable, Sendable {
    /// Which AUv3 render-event family this capture came from.
    public enum Wire: UInt8, Sendable {
        case legacy        // AUMIDIEvent (MIDI 1.0, 1-3 bytes)
        case ump           // AUMIDIEventList packet (Universal MIDI Packet)
        case parameter     // AUParameterEvent (immediate set)
        case parameterRamp // AUParameterEvent (ramped set)
    }

    public var wire: Wire
    public var sampleTime: Double
    public var length: UInt16
    public var cable: UInt8
    public var byte0: UInt8
    public var byte1: UInt8
    public var byte2: UInt8
    /// UMP: first two 32-bit words of the packet (word0 carries MT/group/status).
    public var word0: UInt32
    public var word1: UInt32
    /// UMP: the `MIDIEventList.protocol` the host delivered this packet in
    /// (`MIDIProtocolID` raw value: 1 = MIDI 1.0, 2 = MIDI 2.0; 0 = n/a).
    public var umpProtocol: UInt8
    /// Parameter automation event payload.
    public var parameterAddress: UInt64
    public var parameterValue: Float

    /// Legacy `AUMIDIEvent` capture (the original initializer, unchanged).
    public init(sampleTime: Double = 0, length: UInt16 = 0, cable: UInt8 = 0,
                byte0: UInt8 = 0, byte1: UInt8 = 0, byte2: UInt8 = 0) {
        self.wire = .legacy
        self.sampleTime = sampleTime
        self.length = length
        self.cable = cable
        self.byte0 = byte0
        self.byte1 = byte1
        self.byte2 = byte2
        self.word0 = 0
        self.word1 = 0
        self.umpProtocol = 0
        self.parameterAddress = 0
        self.parameterValue = 0
    }

    /// UMP (`AUMIDIEventList`) packet capture.
    public init(ump word0: UInt32, word1: UInt32, wordCount: UInt16,
                protocolID: UInt8, cable: UInt8, sampleTime: Double) {
        self.wire = .ump
        self.sampleTime = sampleTime
        self.length = wordCount
        self.cable = cable
        self.byte0 = 0
        self.byte1 = 0
        self.byte2 = 0
        self.word0 = word0
        self.word1 = word1
        self.umpProtocol = protocolID
        self.parameterAddress = 0
        self.parameterValue = 0
    }

    /// `AUParameterEvent` capture (host parameter automation driving this AU).
    public init(parameterAddress: UInt64, value: Float, ramp: Bool, sampleTime: Double) {
        self.wire = ramp ? .parameterRamp : .parameter
        self.sampleTime = sampleTime
        self.length = 0
        self.cable = 0
        self.byte0 = 0
        self.byte1 = 0
        self.byte2 = 0
        self.word0 = 0
        self.word1 = 0
        self.umpProtocol = 0
        self.parameterAddress = parameterAddress
        self.parameterValue = value
    }

    /// Coarse classification of the message, for the summary.
    public enum Category: String, Sendable {
        case noteOn, noteOff, polyAftertouch, controlChange, programChange
        case channelAftertouch, pitchBend
        case sysex, systemCommon, clock, start, `continue`, stop, activeSensing, reset
        case parameter, parameterRamp
        case other
    }

    public var category: Category {
        switch wire {
        case .legacy:
            if byte0 < 0x80 { return .other }
            if byte0 < 0xF0 {
                return Self.channelVoiceCategory(status: byte0, data2: byte2)
            }
            return Self.systemCategory(byte0)
        case .ump:
            return umpCategory
        case .parameter:
            return .parameter
        case .parameterRamp:
            return .parameterRamp
        }
    }

    /// Classify a UMP packet from `word0` (and, for channel voice, the embedded
    /// status). Channel-voice messages map onto the same categories as legacy so
    /// the per-type tallies stay comparable; everything else is coarse.
    private var umpCategory: Category {
        let mt = (word0 >> 28) & 0xF
        switch mt {
        case 0x1: // System real-time / common
            return Self.systemCategory(UInt8((word0 >> 16) & 0xFF))
        case 0x2: // MIDI 1.0 channel voice
            return Self.channelVoiceCategory(status: UInt8((word0 >> 16) & 0xFF),
                                             data2: UInt8(word0 & 0x7F))
        case 0x4: // MIDI 2.0 channel voice (velocity lives in word1, not data2)
            return Self.channelVoiceCategory(status: UInt8((word0 >> 16) & 0xFF), data2: 1)
        case 0x3, 0x5: // Data messages (SysEx7 / SysEx8 / mixed-data set)
            return .sysex
        default: // 0x0 utility, 0x6/0x7 reserved, etc.
            return .other
        }
    }

    private static func channelVoiceCategory(status: UInt8, data2: UInt8) -> Category {
        switch status & 0xF0 {
        case 0x80: return .noteOff
        case 0x90: return data2 == 0 ? .noteOff : .noteOn
        case 0xA0: return .polyAftertouch
        case 0xB0: return .controlChange
        case 0xC0: return .programChange
        case 0xD0: return .channelAftertouch
        case 0xE0: return .pitchBend
        default: return .other
        }
    }

    private static func systemCategory(_ status: UInt8) -> Category {
        switch status {
        case 0xF0: return .sysex
        case 0xF8: return .clock
        case 0xFA: return .start
        case 0xFB: return .continue
        case 0xFC: return .stop
        case 0xFE: return .activeSensing
        case 0xFF: return .reset
        default: return .systemCommon
        }
    }

    /// UMP message type (top nibble of `word0`, 0-15); 0 for non-UMP captures.
    public var umpMessageType: UInt8 {
        wire == .ump ? UInt8((word0 >> 28) & 0xF) : 0
    }

    /// UMP group (next nibble of `word0`, 0-15); 0 for non-UMP captures.
    public var umpGroup: UInt8 {
        wire == .ump ? UInt8((word0 >> 24) & 0xF) : 0
    }

    /// 1-16 for channel-voice messages (legacy or UMP MT 2/4), 0 otherwise.
    public var channel: Int {
        switch wire {
        case .legacy:
            guard byte0 >= 0x80 && byte0 < 0xF0 else { return 0 }
            return Int(byte0 & 0x0F) + 1
        case .ump:
            let mt = (word0 >> 28) & 0xF
            guard mt == 0x2 || mt == 0x4 else { return 0 }
            return Int((word0 >> 16) & 0x0F) + 1
        case .parameter, .parameterRamp:
            return 0
        }
    }

    /// A human-readable dump: hex bytes for legacy, hex words for UMP, or the
    /// address/value for a parameter event.
    public var hex: String {
        switch wire {
        case .legacy:
            let count = Int(min(length, 3))
            let bytes = [byte0, byte1, byte2].prefix(max(1, count))
            return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        case .ump:
            let count = Int(min(max(length, 1), 2))
            let words = [word0, word1].prefix(count)
            return words.map { String(format: "%08X", $0) }.joined(separator: " ")
        case .parameter, .parameterRamp:
            return String(format: "addr=%llu val=%.4f", parameterAddress, parameterValue)
        }
    }
}

/// SPSC lock-free ring of `ObservedMidiEvent`. Here the DIRECTION matches the
/// audio tap: the render thread is the PRODUCER (pushes each inbound event) and a
/// UI/report thread is the CONSUMER (drains for display + os_log). A thin alias
/// over the generic SPSCRing; see SPSCRing for the lock-free contract.
public typealias ObservedMidiRing = SPSCRing<ObservedMidiEvent>

public extension SPSCRing where Element == ObservedMidiEvent {
    /// An observed-event ring of `capacity` slots, seeded with an empty event.
    convenience init(capacity: Int) {
        self.init(capacity: capacity, empty: ObservedMidiEvent())
    }
}

/// A rolling tally of observed inbound MIDI, accumulated on the consumer side by
/// draining an `ObservedMidiRing`. Surfaced in the AU panel and the os_log dump
/// to answer "what does AUM route into the node, and how?".
public struct ObservedMidiSummary: Equatable, Sendable {
    public var total = 0
    public var noteOn = 0
    public var noteOff = 0
    public var controlChange = 0
    public var programChange = 0
    public var pitchBend = 0
    public var aftertouch = 0
    public var clock = 0
    public var start = 0
    public var stop = 0
    public var `continue` = 0
    public var sysex = 0
    public var activeSensing = 0
    public var other = 0
    /// Count of UMP (`AUMIDIEventList`) packets seen — the MIDI-2.0-capable path.
    public var ump = 0
    /// Count of host parameter-automation events (immediate set).
    public var parameter = 0
    /// Count of host parameter-automation events delivered as a ramp.
    public var parameterRamp = 0
    /// Bitmask of channels (1-16) seen on channel-voice messages.
    public var channelsSeen: UInt16 = 0
    /// Bitmask of UMP message types (0-15) seen across all UMP packets.
    public var umpMessageTypesSeen: UInt16 = 0
    /// Bitmask of UMP list protocols seen (bit `n` set => `MIDIProtocolID` raw `n`).
    public var umpProtocolsSeen: UInt8 = 0
    /// Hex of the most recent non-realtime event (channel voice / sysex / UMP).
    public var lastMessage = ""
    /// Channel of the most recent channel-voice event (0 if none yet).
    public var lastChannel = 0
    /// Address/value of the most recent parameter-automation event.
    public var lastParameterAddress: UInt64 = 0
    public var lastParameterValue: Float = 0

    public init() {}

    /// Fold one captured event into the tally.
    public mutating func record(_ event: ObservedMidiEvent) {
        total += 1
        switch event.wire {
        case .legacy, .ump:
            recordMessage(event)
        case .parameter:
            parameter += 1
            lastParameterAddress = event.parameterAddress
            lastParameterValue = event.parameterValue
        case .parameterRamp:
            parameterRamp += 1
            lastParameterAddress = event.parameterAddress
            lastParameterValue = event.parameterValue
        }
    }

    /// Fold a wire MIDI message (legacy or UMP) into the per-type tallies. UMP
    /// packets additionally record their message type and negotiated protocol so
    /// the panel/log can show whether AUM delivered MIDI 1.0 or 2.0.
    private mutating func recordMessage(_ event: ObservedMidiEvent) {
        switch event.category {
        case .noteOn: noteOn += 1
        case .noteOff: noteOff += 1
        case .controlChange: controlChange += 1
        case .programChange: programChange += 1
        case .pitchBend: pitchBend += 1
        case .polyAftertouch, .channelAftertouch: aftertouch += 1
        case .clock: clock += 1
        case .start: start += 1
        case .stop: stop += 1
        case .continue: `continue` += 1
        case .sysex: sysex += 1
        case .activeSensing: activeSensing += 1
        case .systemCommon, .reset, .other: other += 1
        case .parameter, .parameterRamp: break // not reachable for wire messages
        }
        if event.wire == .ump {
            ump += 1
            umpMessageTypesSeen |= UInt16(1) << UInt16(event.umpMessageType)
            if event.umpProtocol > 0 && event.umpProtocol < 8 {
                umpProtocolsSeen |= UInt8(1) << event.umpProtocol
            }
        }
        if event.channel > 0 {
            channelsSeen |= UInt16(1 << (event.channel - 1))
            lastChannel = event.channel
        }
        // Keep the last "interesting" message (skip the high-rate clock/sensing).
        switch event.category {
        case .clock, .activeSensing:
            break
        default:
            lastMessage = event.hex
        }
    }

    /// The channels seen, as a sorted list of 1-16 values.
    public var channels: [Int] {
        (1...16).filter { channelsSeen & UInt16(1 << ($0 - 1)) != 0 }
    }

    /// The UMP message types seen, as a sorted list of 0-15 values.
    public var umpMessageTypes: [Int] {
        (0...15).filter { umpMessageTypesSeen & (UInt16(1) << UInt16($0)) != 0 }
    }

    /// The UMP list protocols seen, named (e.g. `["MIDI 2.0"]`).
    public var umpProtocols: [String] {
        var names: [String] = []
        if umpProtocolsSeen & (UInt8(1) << 1) != 0 { names.append("MIDI 1.0") }
        if umpProtocolsSeen & (UInt8(1) << 2) != 0 { names.append("MIDI 2.0") }
        return names
    }

    /// One compact line to os_log under `com.teemow.auv3probe`, so the observed
    /// inbound tally streams alongside the introspection dump on Linux.
    public func log(prefix: String = "observed-midi") {
        Self.log.notice("""
        \(prefix, privacy: .public) total=\(self.total) noteOn=\(self.noteOn) noteOff=\(self.noteOff) \
        cc=\(self.controlChange) pc=\(self.programChange) pitch=\(self.pitchBend) at=\(self.aftertouch) \
        clock=\(self.clock) start=\(self.start) stop=\(self.stop) cont=\(self.continue) \
        sysex=\(self.sysex) sense=\(self.activeSensing) other=\(self.other) \
        ump=\(self.ump) umpMT=\(self.umpMessageTypes.map(String.init).joined(separator: ","), privacy: .public) \
        umpProto=\(self.umpProtocols.joined(separator: ","), privacy: .public) \
        param=\(self.parameter) paramRamp=\(self.parameterRamp) \
        lastParam=\(self.lastParameterAddress)/\(self.lastParameterValue) \
        channels=\(self.channels.map(String.init).joined(separator: ","), privacy: .public) \
        last=\(self.lastMessage, privacy: .public) lastCh=\(self.lastChannel)
        """)
    }

    private static let log = Logger(subsystem: "com.teemow.auv3probe", category: "observed-midi")
}
