import Foundation

// ReconnectingWebSocket is the shared Bonjour-driven WebSocket client used by
// both AUv3 extensions: ProbeAudioTap's TapStreamer (the "ears", which streams
// audio up) and ProbeMidiBrain's BrainController (the "hands", which receives
// MIDI commands down). Both need the exact same lifecycle — discover the daemon,
// dial it, keep the socket alive, and re-dial on drop — so it lives here once.
//
// Threading: all socket state is touched only on the owned serial `queue`, and
// every hook (`onConnect` / `onReceive` / `onDisconnect`) is invoked on it too,
// so callers can mutate their own per-connection state without extra locking.
//
// Lifecycle: once `start()` is called the socket keeps a connection alive until
// `stop()`. If the daemon isn't discovered yet, the host isn't reachable, or the
// socket drops (e.g. mcp-midi-controller restarts), it retries after
// `reconnectDelay`. The host is re-read from DaemonDiscovery on every attempt, so
// a daemon that comes back or moves address is picked up on the next reconnect.
public final class ReconnectingWebSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// The serial queue all socket state and hooks run on. Callers may schedule
    /// their own per-connection work (timers, sends) on it.
    public let queue: DispatchQueue

    /// Called after a socket opens, with the live task (for callers that send).
    public var onConnect: ((URLSessionWebSocketTask) -> Void)?
    /// Called for each inbound message. Leave nil for send-only sockets; the
    /// receive pump still runs so dropped connections are detected.
    public var onReceive: ((URLSessionWebSocketTask.Message) -> Void)?
    /// Called whenever the current socket is torn down (drop, stop, or before a
    /// reconnect), so callers can reset per-connection state.
    public var onDisconnect: (() -> Void)?

    private let path: String
    private let reconnectDelay: TimeInterval

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var shouldRun = false
    private var reconnectScheduled = false

    /// - Parameters:
    ///   - path: the daemon WebSocket path (e.g. `audio-stream`, `midi-control`).
    ///   - label: serial-queue label (also identifies the socket in traces).
    ///   - reconnectDelay: delay between reconnect attempts.
    public init(path: String, label: String, reconnectDelay: TimeInterval = 2) {
        self.path = path
        self.queue = DispatchQueue(label: label)
        self.reconnectDelay = reconnectDelay
        super.init()
    }

    /// Enable the socket and keep it connected (auto-reconnecting).
    public func start() {
        DaemonDiscovery.shared.start()
        queue.async { [self] in
            shouldRun = true
            connectLocked()
        }
    }

    /// Disable the socket and tear down any live connection.
    public func stop() {
        queue.async { [self] in
            shouldRun = false
            teardownLocked()
        }
    }

    // MARK: - Connection lifecycle (all on `queue`)

    /// (Re)open the socket to the auto-discovered daemon.
    private func connectLocked() {
        teardownLocked()
        guard shouldRun else { return }
        guard let host = DaemonDiscovery.shared.currentHost,
              let client = DaemonClient(host: host),
              let url = client.webSocketURL(path: path) else {
            scheduleReconnectLocked()
            return
        }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        receiveLoop(for: task)
        onConnect?(task)
    }

    /// Tear down the current socket without clearing `shouldRun`.
    private func teardownLocked() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        onDisconnect?()
    }

    /// Schedule a single reconnect attempt while still enabled.
    private func scheduleReconnectLocked() {
        guard shouldRun, !reconnectScheduled else { return }
        reconnectScheduled = true
        queue.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self = self else { return }
            self.reconnectScheduled = false
            if self.shouldRun { self.connectLocked() }
        }
    }

    private func receiveLoop(for task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                // Ignore callbacks from a socket we've already replaced.
                guard task === self.task else { return }
                switch result {
                case .success(let message):
                    self.onReceive?(message)
                    self.receiveLoop(for: task)
                case .failure:
                    self.scheduleReconnectLocked()
                }
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { [weak self] in
            guard let self = self, webSocketTask === self.task else { return }
            // The daemon closing (e.g. restart) should bring the connection back.
            self.scheduleReconnectLocked()
        }
    }
}
