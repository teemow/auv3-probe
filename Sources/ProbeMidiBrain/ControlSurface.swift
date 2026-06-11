import Foundation
import ProbeKit

// The daemon→brain control-surface manifest: the wire frame (type
// "controlSurface") pushed over /midi-control after a session import, mirroring
// mcp-midi-controller's `internal/midicontrol.ControlSurface`. It describes the
// current session rig as renderable controls — one entry per session-derived
// device, each control carrying its widget kind and the exact MIDI message
// (type/channel/number) the session mapping stores.
//
// The AU caches the decoded descriptor in `fullState` (so AUM persists it with
// the session) and the plugin UI renders it, emitting the messages locally via
// the engine's surface ring — the surface keeps working when the daemon is
// offline.
public struct ControlSurfaceDescriptor: Codable, Hashable, Sendable {
    /// The wire frame's `type` value (the daemon side's ControlSurfaceType).
    public static let frameType = "controlSurface"

    /// The staged session id the surface was derived from.
    public var session: String
    /// The session's human title (nil when untitled).
    public var title: String?
    public var devices: [Device]
    /// The daemon's session-switch registry: one entry per registered session,
    /// pinned to a Program Change on the reserved session-switch channel.
    /// Rendered as the switcher row above the device rack (tap semantics live
    /// in BrainController's sessionSwitch wire contract). nil/empty when the
    /// daemon has nothing registered (older daemons never send the key).
    public var sessions: [Session]?

    public init(session: String, title: String? = nil, devices: [Device],
                sessions: [Session]? = nil) {
        self.session = session
        self.title = title
        self.devices = devices
        self.sessions = sessions
    }

    /// One registered cross-session switch: tapping it loads `name` via the
    /// pinned Program Change.
    public struct Session: Codable, Hashable, Sendable {
        public var name: String
        public var program: Int
        /// 1-based, like `Msg.channel`.
        public var channel: Int
        /// Marks the daemon's current session (the one this manifest was
        /// derived from / last switched to). Optional on the wire.
        public var current: Bool?

        public init(name: String, program: Int, channel: Int, current: Bool? = nil) {
            self.name = name
            self.program = program
            self.channel = channel
            self.current = current
        }

        public var isCurrent: Bool { current ?? false }

        /// The Program Change this switch emits into AUM.
        public var command: MidiCommand? {
            Msg(type: "pc", channel: channel, number: program).command(value: 0)
        }
    }

    /// One session-derived device (the session device or one hosted AUv3 node)
    /// and its renderable controls.
    public struct Device: Codable, Hashable, Sendable {
        public var name: String
        public var controls: [Control]

        public init(name: String, controls: [Control]) {
            self.name = name
            self.controls = controls
        }
    }

    /// One renderable control. `widget` stays a raw string on the wire so a
    /// newer daemon adding widget kinds never fails the whole frame's decode —
    /// unknown kinds are simply skipped by the UI (`widgetKind` is nil).
    public struct Control: Codable, Hashable, Sendable {
        public var name: String
        public var widget: String
        public var msg: Msg
        /// Named wire values for toggle/trigger/enum widgets, ordered by wire
        /// value (then label) by the daemon, so rendering is deterministic.
        public var values: [NamedValue]?
        /// Fader wire-value bounds when declared (nil = full 0…127 data range).
        public var min: Int?
        public var max: Int?

        public init(name: String, widget: String, msg: Msg,
                    values: [NamedValue]? = nil, min: Int? = nil, max: Int? = nil) {
            self.name = name
            self.widget = widget
            self.msg = msg
            self.values = values
            self.min = min
            self.max = max
        }

        public enum Widget: String, Sendable {
            case fader
            case toggle
            case trigger
            /// "enum" on the wire — pick-one from `values`.
            case picker = "enum"
            case preset
        }

        /// The known widget kind, or nil for kinds this build does not render.
        public var widgetKind: Widget? { Widget(rawValue: widget) }

        /// A fader's wire-value range (defaults to the full MIDI data range).
        public var faderRange: ClosedRange<Double> {
            let lo = Double(Swift.min(127, Swift.max(0, min ?? 0)))
            let hi = Double(Swift.min(127, Swift.max(0, max ?? 127)))
            return lo <= hi ? lo...hi : hi...lo
        }

        /// The wire value a trigger/preset fires with (`values` holds the single
        /// fire value when the daemon declared one; 127 — "pressed" — otherwise).
        public var fireValue: Int { values?.first?.value ?? 127 }
    }

    /// The MIDI message a control emits: the command wire shape reduced to its
    /// address — the value byte comes from the widget interaction.
    public struct Msg: Codable, Hashable, Sendable {
        /// "cc" | "noteOn" | "noteOff" | "pc"
        public var type: String
        /// 1-based, like the command frames.
        public var channel: Int
        /// CC controller / note number / pc program.
        public var number: Int

        public init(type: String, channel: Int, number: Int) {
            self.type = type
            self.channel = channel
            self.number = number
        }

        /// Map to the fixed-size command the engine rings carry. `value` is the
        /// data byte from the widget interaction (velocity for notes, CC value;
        /// ignored for pc, whose program is `number`). nil for message types
        /// this build cannot emit.
        public func command(value: Int) -> MidiCommand? {
            let ch = UInt8(Swift.min(16, Swift.max(1, channel)))
            let num = UInt8(Swift.min(127, Swift.max(0, number)))
            let val = UInt8(Swift.min(127, Swift.max(0, value)))
            switch type {
            case "cc":
                return MidiCommand(kind: .controlChange, channel: ch, data1: num, data2: val)
            case "noteOn":
                return MidiCommand(kind: .noteOn, channel: ch, data1: num, data2: val)
            case "noteOff":
                return MidiCommand(kind: .noteOff, channel: ch, data1: num, data2: 0)
            case "pc":
                return MidiCommand(kind: .programChange, channel: ch, data1: num)
            default:
                return nil
            }
        }

        /// The matching release for a noteOn message (nil for everything else),
        /// so one-shot triggers leave no hanging notes.
        public var releaseCommand: MidiCommand? {
            guard type == "noteOn" else { return nil }
            return Msg(type: "noteOff", channel: channel, number: number).command(value: 0)
        }
    }

    /// One named wire value of a toggle/trigger/enum control.
    public struct NamedValue: Codable, Hashable, Sendable {
        public var label: String
        public var value: Int

        public init(label: String, value: Int) {
            self.label = label
            self.value = value
        }
    }
}
