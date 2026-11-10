import Foundation
import ProbeKit

// TapStreamer drains the realtime ring on a background queue and streams the
// audio to mcp-midi-controller over a WebSocket. Discovery + reconnect live in
// the shared ProbeKit `ReconnectingWebSocket`; this type adds the send side:
// drain the ring, ship interleaved PCM, and emit periodic feature messages.
//
// Wire contract (see docs/auv3-extension.md, "Audio-stream protocol"):
//   - a tap with a name dials `audio-stream?name=<its name>`, one without
//       dials `audio-stream`.
//   - on connect, one TEXT message:  {"type":"format","encoding":"f32le",
//       "channels":<host ch>,"sampleRate":<host Hz>,"source":<the tap's name,
//       or "ProbeAudioTap" when it has none>}
//   - audio: BINARY messages of little-endian Float32 PCM, interleaved across
//       channels at the host sample rate (full fidelity, no downmix/decimation).
//   - ~10 Hz TEXT feature messages: {"type":"features","rms":<f>,"peak":<f>}.
// The receiver side lives in the mcp-midi-controller repo; this end only defines
// and produces the contract.
final class TapStreamer: @unchecked Sendable {
    private let dsp: TapDSP
    private let sampleRate: Double
    private let channels: Int
    private let socket: ReconnectingWebSocket

    // All of the following are touched only on `socket.queue` (via the socket
    // hooks and the drain timer, which is scheduled on that same queue).
    /// The name the present connection was dialled under, nil for none.
    private var name: String?
    private var task: URLSessionWebSocketTask?
    private var timer: DispatchSourceTimer?
    private var drain: UnsafeMutableBufferPointer<Float>
    private var ticksSinceFeature = 0
    // Backpressure: bound the number of audio sends queued in URLSession. If the
    // socket falls behind we drop audio (consistent with the realtime ring's
    // drop-on-overflow policy) rather than letting the queue grow without bound.
    private var inFlight = 0
    private static let maxInFlight = 32

    init(dsp: TapDSP, sampleRate: Double, channels: Int) {
        self.dsp = dsp
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        // Drain in chunks per tick. At 48 kHz stereo a 10 ms tick produces ~960
        // interleaved floats, so 8192 comfortably absorbs bursts after a hiccup
        // (~85 ms of stereo) and keeps the byte rate (~384 KB/s) flowing.
        self.drain = UnsafeMutableBufferPointer<Float>.allocate(capacity: 8192)
        self.socket = ReconnectingWebSocket(path: "audio-stream",
                                            label: "com.teemow.auv3probe.tapstreamer")
        socket.onConnect = { [weak self] task in
            guard let self = self else { return }
            self.task = task
            self.sendFormat(on: task)
            self.startTimer()
        }
        socket.onDisconnect = { [weak self] in
            guard let self = self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.task = nil
            self.inFlight = 0
            self.ticksSinceFeature = 0
        }
    }

    deinit {
        drain.deallocate()
    }

    /// Enable streaming under `name` (nil: without one) and keep it connected
    /// (auto-reconnecting). The host comes from Bonjour discovery
    /// (DaemonDiscovery.shared.currentHost). Starting a tap that already
    /// streams dials again, so a changed name reaches the daemon.
    func start(name: String?) {
        // Ahead of the socket's own start on the same queue, so the format
        // message of the connection it opens carries this name.
        socket.queue.async { [weak self] in self?.name = name }
        socket.start(query: Self.query(name: name))
    }

    func stop() { socket.stop() }

    // MARK: - Send side (all on `socket.queue`)

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: socket.queue)
        t.schedule(deadline: .now() + 0.01, repeating: 0.01)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    /// What a tap without a name calls itself in the format message.
    static let unnamedSource = "ProbeAudioTap"

    /// The query a tap dials the daemon with: its name, when it has one. The
    /// daemon keeps the streams of several taps apart by it.
    static func query(name: String?) -> [URLQueryItem] {
        guard let name else { return [] }
        return [URLQueryItem(name: "name", value: name)]
    }

    /// The format message that opens a connection.
    static func formatMessage(channels: Int, sampleRate: Double, name: String?) -> [String: Any] {
        [
            "type": "format",
            "encoding": "f32le",
            "channels": channels,
            "sampleRate": sampleRate,
            "source": name ?? unnamedSource,
        ]
    }

    private func sendFormat(on task: URLSessionWebSocketTask) {
        let header = Self.formatMessage(channels: channels, sampleRate: sampleRate, name: name)
        if let data = try? JSONSerialization.data(withJSONObject: header),
           let json = String(data: data, encoding: .utf8) {
            task.send(.string(json)) { _ in }
        }
    }

    private func tick() {
        guard let task = task else { return }

        // Drain whatever the render thread has produced (interleaved float32 at
        // the host rate) and ship it, unless we have too many sends in flight
        // (socket fell behind) — then drop.
        var produced = dsp.ring.read(into: drain)
        while produced > 0 {
            if inFlight >= Self.maxInFlight { break }
            let bytes = produced * MemoryLayout<Float>.size
            let data = drain.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: bytes) {
                Data(bytes: $0, count: bytes)
            }
            inFlight += 1
            task.send(.data(data)) { [weak self] _ in
                // Completion may run on an arbitrary queue; hop back to our serial
                // queue to mutate inFlight safely.
                self?.socket.queue.async { if let self = self { self.inFlight -= 1 } }
            }
            if produced < drain.count { break }
            produced = dsp.ring.read(into: drain)
        }

        // ~10 Hz feature messages.
        ticksSinceFeature += 1
        if ticksSinceFeature >= 10 {
            ticksSinceFeature = 0
            let levels = dsp.levels
            let msg: [String: Any] = ["type": "features", "rms": levels.rms, "peak": levels.peak]
            if let data = try? JSONSerialization.data(withJSONObject: msg),
               let json = String(data: data, encoding: .utf8) {
                task.send(.string(json)) { _ in }
            }
        }
    }
}
