import Foundation
import AVFoundation
import AudioToolbox
import os

// HostDiagnosticsReporter is the view-independent assembler of the host
// diagnostics snapshot. It replaces the capture timer that used to live in the
// SwiftUI view model (and therefore died the moment the plugin UI was closed):
// the reporter is started with the AU's render resources and runs for as long as
// the appex is hosted, regardless of whether anyone has the panel open.
//
// Each tick it merges the two provenance halves of a `HostDiagnostics`:
//
//   - the SANCTIONED render-thread readback (transport, musical context, render
//     timestamp), captured on the realtime thread and published via the engine's
//     non-blocking lock — the reporter only ever *reads* the published copy
//     through the supplied `renderSnapshot` provider, it never touches the
//     render thread itself;
//   - the off-thread reads (AU identity/capabilities + MIDI negotiation from the
//     hosted `AUAudioUnit`, plus the AVAudioSession / CoreMIDI / environment
//     backdoors), all plain pure reads done on the reporter's background queue.
//
// It owns the latest assembled snapshot (thread-safe), fans it out to an
// optional `onSnapshot` sink (the diagnostics streamer subscribes here to ship
// it over the `/diagnostics` WebSocket), and — as the fallback sink when no
// stream is connected — dumps it to os_log on a slower cadence so it still
// reaches idevicesyslog. The SwiftUI panel becomes a passive reader of `latest`.
//
// Lives in ProbeKit and is decoupled from any one engine via the
// `RenderSnapshotProvider` closure, so both AUv3 extensions (ProbeMidiBrain's
// BrainEngine and ProbeAudioTap) reuse it: each wires its own engine's
// render-thread snapshot read and passes its own `source` label.
public final class HostDiagnosticsReporter: @unchecked Sendable {
    /// Returns the sanctioned render-thread readback (transport + musical context
    /// + render timestamp). Called on the reporter's background queue; the
    /// implementation reads the engine's published copy via its non-blocking lock,
    /// so this never blocks or touches the realtime thread.
    public typealias RenderSnapshotProvider = @Sendable () -> HostRenderSnapshot

    /// Label identifying which appex produced the snapshot (e.g.
    /// `"ProbeMidiBrain"` / `"ProbeAudioTap"`), copied into `HostDiagnostics.source`.
    /// Readable so the diagnostics streamer can tag its socket/queue label.
    public let source: String
    /// Assembly cadence (~1 Hz by default).
    private let interval: TimeInterval
    /// Dump the assembled snapshot to os_log every Nth tick (the fallback sink when
    /// the `/diagnostics` stream is unavailable). 0 disables logging entirely.
    private let logEveryTicks: Int

    // The hosted unit, read off-thread for the AU-surface sections. Held weakly:
    // the AU owns the reporter (it is created with render resources), so a strong
    // back-reference would be a retain cycle.
    private weak var audioUnit: AUAudioUnit?
    private let renderSnapshot: RenderSnapshotProvider

    /// Invoked on the reporter's queue with each freshly assembled snapshot. The
    /// diagnostics streamer subscribes here to send on the reporter's cadence.
    public var onSnapshot: (@Sendable (HostDiagnostics) -> Void)?

    // Timer + tick counter are touched only on `queue`.
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var tick = 0

    /// The most recently assembled snapshot, for the passive UI reader and any
    /// on-demand consumer. Lock-protected (not the realtime path).
    private let latestBox = OSAllocatedUnfairLockBox<HostDiagnostics?>(nil)

    /// - Parameters:
    ///   - source: appex label copied into `HostDiagnostics.source`.
    ///   - audioUnit: the hosted unit, read off-thread for the AU-surface sections.
    ///   - interval: assembly cadence (default ~1 Hz).
    ///   - logEveryTicks: os_log dump cadence in ticks (default 3; 0 disables).
    ///   - renderSnapshot: provider for the sanctioned render-thread readback.
    public init(source: String,
                audioUnit: AUAudioUnit?,
                interval: TimeInterval = 1,
                logEveryTicks: Int = 3,
                renderSnapshot: @escaping RenderSnapshotProvider) {
        self.source = source
        self.audioUnit = audioUnit
        self.interval = interval
        self.logEveryTicks = max(0, logEveryTicks)
        self.renderSnapshot = renderSnapshot
        self.queue = DispatchQueue(label: "com.teemow.auv3probe.diagnostics.reporter.\(source)")
    }

    /// Start the background timer and assemble immediately so `latest` is
    /// populated without waiting a full interval. Idempotent.
    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            assembleLocked()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval)
            t.setEventHandler { [weak self] in self?.assembleLocked() }
            timer = t
            t.resume()
        }
    }

    /// Stop the background timer. Idempotent. The last assembled snapshot remains
    /// readable via `latest`.
    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// The most recently assembled snapshot (nil until the first tick). Safe to
    /// read from any thread; the UI polls this.
    public var latest: HostDiagnostics? { latestBox.value }

    /// Assemble a fresh snapshot synchronously, publish it (updates `latest`,
    /// fires `onSnapshot`), and return it. Use for the panel's on-demand "dump"
    /// button. Runs on the caller's thread (all reads are off-thread-safe),
    /// independent of the timer. Does NOT advance the os_log cadence — that is
    /// owned solely by the timer path (`assembleLocked`) so the cadence counter
    /// is only ever touched on the reporter's queue.
    @discardableResult
    public func capture() -> HostDiagnostics {
        let snapshot = assemble()
        publish(snapshot)
        return snapshot
    }

    // MARK: - Assembly

    /// Timer/`start` entry point: assemble + publish + log on cadence, all on the
    /// reporter's queue (so the cadence counter stays single-threaded).
    private func assembleLocked() {
        let snapshot = assemble()
        publish(snapshot)
        logOnCadence(snapshot)
    }

    /// Build the full envelope by merging the render-thread readback with the
    /// off-thread reads. Pure reads only — safe off the render thread.
    private func assemble() -> HostDiagnostics {
        var snapshot = HostDiagnostics()
        snapshot.capturedAt = Date()
        snapshot.source = source

        // Sanctioned render-thread readback (published copy).
        let render = renderSnapshot()
        snapshot.transport = render.transport
        snapshot.musicalContext = render.musicalContext
        snapshot.renderTime = render.renderTime

        // Off-thread AU-surface + render-config reads.
        if let au = audioUnit {
            snapshot.audioUnit = HostDiagnosticsCollector.audioUnit(au)
            snapshot.midi = HostDiagnosticsCollector.midiNegotiation(au)
            snapshot.render = renderConfig(au)
        }

        // Backdoors.
        snapshot.audioSession = HostDiagnosticsCollector.audioSession()
        snapshot.coreMIDI = HostDiagnosticsCollector.coreMIDI()
        snapshot.environment = HostDiagnosticsCollector.environment()
        return snapshot
    }

    /// The negotiated render-config slice (kept for the panel), read off-thread
    /// from the AU.
    private func renderConfig(_ au: AUAudioUnit) -> HostDiagnostics.Render {
        var render = HostDiagnostics.Render()
        render.maximumFramesToRender = Int(au.maximumFramesToRender)
        render.midiOutputNames = au.midiOutputNames
        let outputs = au.outputBusses
        render.outputBusFormats = (0..<outputs.count).map { index in
            let format = outputs[index].format
            return "\(Int(format.sampleRate))Hz ch\(format.channelCount)"
        }
        return render
    }

    /// Store as `latest` and fan out to `onSnapshot`. Safe to call from any
    /// thread (the box is lock-protected; `onSnapshot` is set once before start).
    private func publish(_ snapshot: HostDiagnostics) {
        latestBox.value = snapshot
        onSnapshot?(snapshot)
    }

    /// Dump the snapshot to os_log every Nth tick. Only ever called from the
    /// timer path (`assembleLocked`) on the reporter's queue, so `tick` needs no
    /// synchronisation.
    private func logOnCadence(_ snapshot: HostDiagnostics) {
        guard logEveryTicks > 0 else { return }
        tick += 1
        if tick % logEveryTicks == 0 {
            snapshot.log()
        }
    }
}

/// The sanctioned host-block readback the render thread captures (transport,
/// musical context, and the render `AudioTimeStamp`), bundled so the reporter
/// can merge it into a full `HostDiagnostics`. The engine publishes the live
/// values via its non-blocking lock; the reporter reads the published copy off
/// the render thread through the provider closure.
public struct HostRenderSnapshot: Sendable, Equatable {
    public var transport: HostDiagnostics.Transport
    public var musicalContext: HostDiagnostics.MusicalContext
    public var renderTime: HostDiagnostics.RenderTimestamp

    public init(transport: HostDiagnostics.Transport = HostDiagnostics.Transport(),
                musicalContext: HostDiagnostics.MusicalContext = HostDiagnostics.MusicalContext(),
                renderTime: HostDiagnostics.RenderTimestamp = HostDiagnostics.RenderTimestamp()) {
        self.transport = transport
        self.musicalContext = musicalContext
        self.renderTime = renderTime
    }
}
