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

/// One captured inbound MIDI event, as the AUv3 render block sees it. A trivially
/// copyable value type (no retains on the audio thread). The legacy AUMIDIEvent
/// carries at most three bytes inline; `length` is the host-reported byte count,
/// which can exceed 3 (e.g. a sysex leader) even though only `byte0…2` are kept.
public struct ObservedMidiEvent: Equatable, Sendable {
    public var sampleTime: Double
    public var length: UInt16
    public var cable: UInt8
    public var byte0: UInt8
    public var byte1: UInt8
    public var byte2: UInt8

    public init(sampleTime: Double = 0, length: UInt16 = 0, cable: UInt8 = 0,
                byte0: UInt8 = 0, byte1: UInt8 = 0, byte2: UInt8 = 0) {
        self.sampleTime = sampleTime
        self.length = length
        self.cable = cable
        self.byte0 = byte0
        self.byte1 = byte1
        self.byte2 = byte2
    }

    /// Coarse classification of the leading status byte, for the summary.
    public enum Category: String, Sendable {
        case noteOn, noteOff, polyAftertouch, controlChange, programChange
        case channelAftertouch, pitchBend
        case sysex, systemCommon, clock, start, `continue`, stop, activeSensing, reset
        case other
    }

    public var category: Category {
        let status = byte0
        if status < 0x80 { return .other }
        if status < 0xF0 {
            switch status & 0xF0 {
            case 0x80: return .noteOff
            case 0x90: return byte2 == 0 ? .noteOff : .noteOn
            case 0xA0: return .polyAftertouch
            case 0xB0: return .controlChange
            case 0xC0: return .programChange
            case 0xD0: return .channelAftertouch
            case 0xE0: return .pitchBend
            default: return .other
            }
        }
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

    /// 1-16 for channel-voice messages, 0 otherwise.
    public var channel: Int {
        let status = byte0
        guard status >= 0x80 && status < 0xF0 else { return 0 }
        return Int(status & 0x0F) + 1
    }

    /// Hex dump of the captured bytes, e.g. `B0 11 40`.
    public var hex: String {
        let count = Int(min(length, 3))
        let bytes = [byte0, byte1, byte2].prefix(max(1, count))
        return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
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
    /// Bitmask of channels (1-16) seen on channel-voice messages.
    public var channelsSeen: UInt16 = 0
    /// Hex of the most recent non-realtime event (channel voice / sysex).
    public var lastMessage = ""
    /// Channel of the most recent channel-voice event (0 if none yet).
    public var lastChannel = 0

    public init() {}

    /// Fold one captured event into the tally.
    public mutating func record(_ event: ObservedMidiEvent) {
        total += 1
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

    /// One compact line to os_log under `com.teemow.auv3probe`, so the observed
    /// inbound tally streams alongside the introspection dump on Linux.
    public func log(prefix: String = "observed-midi") {
        Self.log.notice("""
        \(prefix, privacy: .public) total=\(self.total) noteOn=\(self.noteOn) noteOff=\(self.noteOff) \
        cc=\(self.controlChange) pc=\(self.programChange) pitch=\(self.pitchBend) at=\(self.aftertouch) \
        clock=\(self.clock) start=\(self.start) stop=\(self.stop) cont=\(self.continue) \
        sysex=\(self.sysex) sense=\(self.activeSensing) other=\(self.other) \
        channels=\(self.channels.map(String.init).joined(separator: ","), privacy: .public) \
        last=\(self.lastMessage, privacy: .public) lastCh=\(self.lastChannel)
        """)
    }

    private static let log = Logger(subsystem: "com.teemow.auv3probe", category: "observed-midi")
}
