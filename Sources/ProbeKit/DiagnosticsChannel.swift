import Foundation
import AVFoundation
import AudioToolbox

// DiagnosticsChannel bundles the two halves of an appex's host-diagnostics
// channel — the `HostDiagnosticsReporter` (assembles snapshots) and the
// `DiagnosticsStreamer` (ships them over `/diagnostics`) — into one object an
// AUv3 extension can own with render resources and tear down with them.
//
// It exists so both extensions (ProbeMidiBrain, ProbeAudioTap) wire diagnostics
// identically instead of repeating the construct/start/stop dance: the
// `logEveryTicks: 0` convention (the streamer owns the os_log fallback) and the
// start/stop ordering (streamer stopped before the reporter it subscribes to)
// live here once. Each extension supplies only its own `source` label and its
// engine-specific render-thread snapshot provider.
public final class DiagnosticsChannel: @unchecked Sendable {
    public let reporter: HostDiagnosticsReporter
    public let streamer: DiagnosticsStreamer

    /// - Parameters:
    ///   - source: appex label copied into `HostDiagnostics.source`.
    ///   - audioUnit: the hosted unit, read off-thread for the AU-surface sections.
    ///   - renderSnapshot: provider for the sanctioned render-thread readback.
    public init(source: String,
                audioUnit: AUAudioUnit,
                renderSnapshot: @escaping HostDiagnosticsReporter.RenderSnapshotProvider) {
        reporter = HostDiagnosticsReporter(source: source,
                                           audioUnit: audioUnit,
                                           logEveryTicks: 0,
                                           renderSnapshot: renderSnapshot)
        streamer = DiagnosticsStreamer(reporter: reporter)
    }

    /// Begin assembling + streaming. Start the reporter first so a snapshot may
    /// exist by the time the streamer connects.
    public func start() {
        reporter.start()
        streamer.start()
    }

    /// Stop streaming + assembling. Stop the streamer first since it subscribes
    /// to the reporter's sink.
    public func stop() {
        streamer.stop()
        reporter.stop()
    }

    /// The most recently assembled snapshot (nil until the first tick).
    public var latest: HostDiagnostics? { reporter.latest }

    /// Force an immediate capture (the panel's on-demand "dump" button), routed
    /// through the reporter so the snapshot also reaches any connected stream.
    @discardableResult
    public func capture() -> HostDiagnostics { reporter.capture() }
}
