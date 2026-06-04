import Foundation
import os
import Atomics
import ProbeKit

// TapStreamer drains the realtime ring on a background queue and streams the
// audio to mcp-midi-controller over a WebSocket. It reuses ProbeKit's
// DaemonClient host parsing (`webSocketURL(path:)`) so the stream target matches
// the host the rest of the rig uses.
//
// Wire contract (see docs/auv3-extension.md, "Audio-stream protocol"):
//   - on connect, one TEXT message:  {"type":"format","encoding":"f32le",
//       "channels":1,"sampleRate":<decimated Hz>,"source":"ProbeAudioTap"}
//   - audio: BINARY messages of little-endian Float32 mono PCM (decimated).
//   - ~10 Hz TEXT feature messages: {"type":"features","rms":<f>,"peak":<f>}.
// The receiver side lives in the mcp-midi-controller repo; this end only defines
// and produces the contract.
final class TapStreamer: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let dsp: TapDSP
    private let sampleRate: Double
    private let queue = DispatchQueue(label: "com.teemow.auv3probe.tapstreamer")

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var timer: DispatchSourceTimer?
    private var drain: UnsafeMutableBufferPointer<Float>
    private var ticksSinceFeature = 0
    // Backpressure: bound the number of audio sends queued in URLSession. If the
    // socket falls behind we drop audio (consistent with the realtime ring's
    // drop-on-overflow policy) rather than letting the queue grow without bound.
    private var inFlight = 0
    private static let maxInFlight = 32

    /// Observable status for the UI.
    let connected = ManagedAtomic<Bool>(false)
    let lastError = OSAllocatedUnfairLockBox<String?>(nil)

    init(dsp: TapDSP, sampleRate: Double) {
        self.dsp = dsp
        self.sampleRate = sampleRate
        // Drain in chunks of up to ~10 ms of decimated audio per tick.
        self.drain = UnsafeMutableBufferPointer<Float>.allocate(capacity: 4096)
        super.init()
    }

    deinit {
        drain.deallocate()
    }

    /// Decimated (streamed) sample rate.
    private var streamRate: Double { sampleRate / Double(max(1, dsp.decimation.load(ordering: .relaxed))) }

    func start(host: String) {
        queue.async { [self] in
            stopLocked()
            guard let client = DaemonClient(host: host),
                  let url = client.webSocketURL(path: "audio-stream") else {
                lastError.value = "bad host"
                return
            }
            let config = URLSessionConfiguration.default
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: url)
            self.session = session
            self.task = task
            task.resume()
            receiveLoop()
            sendFormat()
            startTimer()
        }
    }

    func stop() {
        queue.async { [self] in stopLocked() }
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        inFlight = 0
        ticksSinceFeature = 0
        connected.store(false, ordering: .relaxed)
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.01, repeating: 0.01)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func sendFormat() {
        let header: [String: Any] = [
            "type": "format",
            "encoding": "f32le",
            "channels": 1,
            "sampleRate": streamRate,
            "source": "ProbeAudioTap",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: header),
           let json = String(data: data, encoding: .utf8) {
            task?.send(.string(json)) { _ in }
        }
    }

    private func tick() {
        guard let task = task else { return }

        // Drain whatever the render thread has produced and ship it, unless we
        // have too many sends in flight (socket fell behind) — then drop.
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
                self?.queue.async { if let self = self { self.inFlight -= 1 } }
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

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.receiveLoop()
            case .failure(let error):
                self.lastError.value = error.localizedDescription
                self.connected.store(false, ordering: .relaxed)
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        connected.store(true, ordering: .relaxed)
        lastError.value = nil
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        connected.store(false, ordering: .relaxed)
    }
}

/// A tiny lock-protected box for a value shared between the stream queue and the
/// UI thread (the last error string). Not on the realtime path.
final class OSAllocatedUnfairLockBox<Value>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>
    init(_ initial: Value) { lock = OSAllocatedUnfairLock(initialState: initial) }
    var value: Value {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
