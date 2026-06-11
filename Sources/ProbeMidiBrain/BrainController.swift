import Foundation
import ProbeKit

// BrainController is the "hands" counterpart of ProbeAudioTap's TapStreamer: it
// dials mcp-midi-controller over a WebSocket and receives MIDI command frames
// the daemon pushes (driven by the agent's play_notes / send_midi /
// set_transport tools). Each decoded command is enqueued on the engine's
// lock-free MidiCommandRing; the realtime render block drains the ring and emits
// the bytes via the host midiOut — so agent commands flow through AUM's MIDI
// routing exactly like a hardware controller.
//
// Discovery + reconnect live in the shared ProbeKit `ReconnectingWebSocket`;
// this type only decodes inbound frames (on the socket's queue) and pushes them
// onto the ring. The render thread only ever touches the ring.
//
// Wire contract (see docs/auv3-extension.md, "MIDI-control protocol"); the
// daemon side lives in mcp-midi-controller's internal/midicontrol:
//   - daemon -> brain TEXT frames, one JSON command each:
//       {"type":"noteOn","channel":1,"note":60,"velocity":100}
//       {"type":"noteOff","channel":1,"note":60}
//       {"type":"cc","channel":1,"controller":17,"value":64}
//       {"type":"pc","channel":1,"program":3}
//       {"type":"transport","action":"start"|"stop"|"continue"}
//   - plus the control-surface manifest the daemon pushes after a session
//     import (unknown frame types are silently dropped, so older builds stay
//     compatible):
//       {"type":"controlSurface","session":"...","title":"...","devices":[...]}
//     Decoded into ControlSurfaceDescriptor and handed to `onControlSurface`
//     (the AU caches it in fullState and the plugin UI renders it).
//   - brain -> daemon TEXT frames (the only upstream message): the session
//     switcher row was tapped, the brain already emitted the Program Change
//     into AUM locally, and the daemon should follow (update its current
//     session, re-import, re-push):
//       {"type":"sessionSwitch","program":3}
//     Best-effort sync — with the daemon offline the local PC still switches
//     the session, and the daemon re-syncs on the next download/connect.
final class BrainController {
    private let ring: MidiCommandRing
    private let socket: ReconnectingWebSocket
    // Reused across frames (decoding runs only on the socket's serial queue).
    private let decoder = JSONDecoder()
    // The live task, for upstream sends. Touched only on the socket's queue.
    private var task: URLSessionWebSocketTask?

    /// Called (on the socket's queue) with each decoded control-surface
    /// manifest the daemon pushes. Set by the AU before `start()`.
    var onControlSurface: ((ControlSurfaceDescriptor) -> Void)?

    init(ring: MidiCommandRing) {
        self.ring = ring
        self.socket = ReconnectingWebSocket(path: "midi-control",
                                            label: "com.teemow.auv3probe.braincontroller")
        socket.onReceive = { [weak self] message in self?.handle(message) }
        socket.onConnect = { [weak self] task in self?.task = task }
        socket.onDisconnect = { [weak self] in self?.task = nil }
    }

    /// Enable the control channel and keep it connected (auto-reconnecting). The
    /// host comes from Bonjour discovery (DaemonDiscovery.shared.currentHost).
    func start() { socket.start() }

    func stop() { socket.stop() }

    /// Send the upstream sessionSwitch frame (see the wire contract above).
    /// Fire-and-forget: with no daemon connected the frame is simply not sent.
    func sendSessionSwitch(program: Int) {
        socket.queue.async { [weak self] in
            guard let task = self?.task else { return }
            let frame = #"{"type":"sessionSwitch","program":\#(program)}"#
            task.send(.string(frame)) { _ in } // drop send errors (best-effort)
        }
    }

    /// Decode one inbound frame and enqueue it. Called on the socket's queue.
    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let d):
            data = d
        case .string(let s):
            data = Data(s.utf8)
        @unknown default:
            return
        }
        guard let frame = try? decoder.decode(CommandFrame.self, from: data) else { return }
        if frame.type == ControlSurfaceDescriptor.frameType {
            // Not a MIDI command: the manifest goes to the AU (cache + UI),
            // never onto the realtime ring.
            if let surface = try? decoder.decode(ControlSurfaceDescriptor.self, from: data) {
                onControlSurface?(surface)
            }
            return
        }
        guard let cmd = frame.toMidiCommand() else { return }
        // Push onto the lock-free ring; the render thread drains it. Overflow is
        // dropped by the ring (returns false) — acceptable under command bursts.
        _ = ring.push(cmd)
    }
}

/// The JSON command envelope the daemon pushes (internal/midicontrol.Command).
/// Decoded off the networking thread, then mapped to a fixed-size MidiCommand.
private struct CommandFrame: Decodable {
    var type: String
    var channel: Int?
    var note: Int?
    var velocity: Int?
    var controller: Int?
    var value: Int?
    var program: Int?
    var action: String?

    func toMidiCommand() -> MidiCommand? {
        let ch = UInt8(clamping: max(1, channel ?? 1))
        switch type {
        case "noteOn":
            return MidiCommand(kind: .noteOn, channel: ch,
                               data1: byte(note), data2: byte(velocity ?? 100))
        case "noteOff":
            return MidiCommand(kind: .noteOff, channel: ch,
                               data1: byte(note), data2: byte(velocity ?? 0))
        case "cc":
            return MidiCommand(kind: .controlChange, channel: ch,
                               data1: byte(controller), data2: byte(value))
        case "pc":
            return MidiCommand(kind: .programChange, channel: ch, data1: byte(program))
        case "transport":
            switch action {
            case "start": return MidiCommand(kind: .transportStart)
            case "stop": return MidiCommand(kind: .transportStop)
            case "continue": return MidiCommand(kind: .transportContinue)
            default: return nil
            }
        default:
            return nil
        }
    }

    private func byte(_ v: Int?) -> UInt8 {
        UInt8(min(127, max(0, v ?? 0)))
    }
}
