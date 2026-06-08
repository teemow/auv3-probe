import Foundation
import AVFoundation
import os

// DiagnosticsStreamer is the send side for the host-diagnostics channel — the
// "what can the brain read?" counterpart to ProbeAudioTap's TapStreamer (audio
// up) and ProbeMidiBrain's BrainController (MIDI down). It ships the assembled
// `HostDiagnostics` envelope to mcp-midi-controller over the shared
// `ReconnectingWebSocket` on path `diagnostics`, so the daemon (and the
// `get_host_diagnostics` MCP tool behind it) sees the live host surface even
// when nobody has the plugin's introspection panel open.
//
// It does NOT assemble snapshots itself — that is the `HostDiagnosticsReporter`'s
// job (it owns the timer and merges the render-thread readback with the
// off-thread reads). The streamer subscribes to the reporter's `onSnapshot`
// sink and forwards whatever it produces. Three triggers feed the wire:
//
//   - on connect: the latest assembled snapshot is sent immediately (or a fresh
//     one is forced via `reporter.capture()` if none exists yet), so a freshly
//     connected daemon gets the full state without waiting a cadence tick;
//   - on cadence: every snapshot the reporter publishes (~1 Hz) is forwarded;
//   - on route-change / interruption: an `AVAudioSession` notification forces a
//     fresh `reporter.capture()` so the delta (new route, channels, latencies,
//     interruption) reaches the daemon promptly rather than on the next tick.
//
// os_log fallback: when no socket is connected the snapshot still has to reach
// idevicesyslog (the Linux-side dev loop), so the streamer dumps it to os_log on
// a throttled cadence. Wiring that delegates the fallback to the streamer should
// construct the reporter with `logEveryTicks: 0` to avoid double-logging; the
// reporter then only logs when its sink (this streamer) isn't connected.
//
// Wire contract (see docs/auv3-extension.md, "Diagnostics protocol"); the
// receiver lives in mcp-midi-controller's internal/diagnostics:
//   - the daemon reads TEXT frames, each one a compact single-line JSON
//     `HostDiagnostics` snapshot (schemaVersion + transport/musicalContext/
//     renderTime/render/audioUnit/midi/audioSession/coreMIDI/environment).
public final class DiagnosticsStreamer: @unchecked Sendable {
    private let socket: ReconnectingWebSocket
    private let source: String

    // The reporter that assembles snapshots. Held weakly: the AU owns both the
    // reporter and this streamer (they are created with render resources), and
    // the reporter's `onSnapshot` closure captures the streamer weakly, so a
    // strong reference here would be redundant ownership at best and is avoided
    // to keep lifecycle solely in the AU's hands.
    private weak var reporter: HostDiagnosticsReporter?

    /// The most recently assembled snapshot, cached so `onConnect` can send the
    /// full state immediately. Written from the reporter's queue, read from the
    /// socket's queue — lock-protected (not a realtime path).
    private let latestBox = OSAllocatedUnfairLockBox<HostDiagnostics?>(nil)

    // The following are touched only on `socket.queue` (the socket hooks and the
    // send path scheduled onto it).
    private var task: URLSessionWebSocketTask?
    // Backpressure: at most one diagnostics send in flight. Snapshots are
    // low-frequency (~1 Hz) but can be sizeable (parameter tree, endpoint list),
    // so if the socket falls behind we drop the newer snapshot — the next tick
    // ships the freshest state anyway.
    private var inFlight = false
    private var fallbackTick = 0

    /// Dump the snapshot to os_log every Nth time it cannot be streamed (socket
    /// not connected). 0 disables the fallback entirely.
    private let fallbackLogEveryTicks: Int

    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - reporter: the snapshot assembler to subscribe to. This streamer
    ///     installs itself as the reporter's `onSnapshot` sink.
    ///   - fallbackLogEveryTicks: os_log fallback cadence, in disconnected
    ///     snapshots, when the stream is down (default 3; 0 disables).
    ///   - notificationCenter: route-change/interruption source (injectable for
    ///     tests; defaults to `.default`).
    public init(reporter: HostDiagnosticsReporter,
                fallbackLogEveryTicks: Int = 3,
                notificationCenter: NotificationCenter = .default) {
        self.reporter = reporter
        self.source = reporter.source
        self.fallbackLogEveryTicks = max(0, fallbackLogEveryTicks)
        self.notificationCenter = notificationCenter
        self.socket = ReconnectingWebSocket(path: "diagnostics",
                                            label: "com.teemow.auv3probe.diagnosticsstreamer.\(reporter.source)")

        reporter.onSnapshot = { [weak self] snapshot in self?.ingest(snapshot) }
        socket.onConnect = { [weak self] task in self?.handleConnect(task) }
        socket.onDisconnect = { [weak self] in self?.handleDisconnect() }
    }

    deinit {
        removeObservers()
    }

    /// Enable streaming and keep it connected (auto-reconnecting). The host comes
    /// from Bonjour discovery (DaemonDiscovery.shared.currentHost). Also begins
    /// listening for route-change/interruption deltas.
    public func start() {
        registerObservers()
        socket.start()
    }

    /// Disable streaming, tear down the connection, and stop listening for deltas.
    public func stop() {
        removeObservers()
        socket.stop()
    }

    // MARK: - Reporter sink

    /// Called on the reporter's queue with each freshly assembled snapshot. Cache
    /// it for `onConnect`, then hop to the socket's queue to send.
    private func ingest(_ snapshot: HostDiagnostics) {
        latestBox.value = snapshot
        socket.queue.async { [weak self] in self?.send(snapshot) }
    }

    // MARK: - Socket lifecycle (all on `socket.queue`)

    private func handleConnect(_ task: URLSessionWebSocketTask) {
        self.task = task
        self.inFlight = false
        self.fallbackTick = 0
        HostDiagnostics.log.notice("diagnostics stream connected source=\(self.source, privacy: .public)")
        // Send the full state right away. If the reporter has already assembled a
        // snapshot, ship that; otherwise force a capture (which assembles, fires
        // `onSnapshot`, and routes back through `ingest` → `send`).
        if let latest = latestBox.value {
            send(latest)
        } else {
            reporter?.capture()
        }
    }

    private func handleDisconnect() {
        self.task = nil
        self.inFlight = false
    }

    // MARK: - Send (all on `socket.queue`)

    private func send(_ snapshot: HostDiagnostics) {
        guard let task = task else {
            fallbackLog(snapshot)
            return
        }
        // Drop if a send is still in flight; the next snapshot carries the
        // freshest state.
        guard !inFlight else { return }
        guard let data = snapshot.jsonData(),
              let json = String(data: data, encoding: .utf8) else { return }
        inFlight = true
        task.send(.string(json)) { [weak self] _ in
            // Completion may run on an arbitrary queue; hop back to our serial
            // queue to clear the in-flight flag safely.
            self?.socket.queue.async { self?.inFlight = false }
        }
    }

    /// os_log fallback sink: when the stream is down, still surface the snapshot
    /// to idevicesyslog on a throttled cadence so the dev loop keeps data.
    private func fallbackLog(_ snapshot: HostDiagnostics) {
        guard fallbackLogEveryTicks > 0 else { return }
        fallbackTick += 1
        if fallbackTick % fallbackLogEveryTicks == 0 {
            snapshot.log(prefix: "diagnostics-fallback")
        }
    }

    // MARK: - Route-change / interruption deltas

    private func registerObservers() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [
            AVAudioSession.routeChangeNotification,
            AVAudioSession.interruptionNotification,
        ]
        observers = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                // Force a fresh assembly so the delta (new route/channels/latency
                // or interruption) reaches the daemon promptly. `capture()`
                // publishes through `onSnapshot` → `ingest` → `send`.
                self?.reporter?.capture()
            }
        }
    }

    private func removeObservers() {
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
}
