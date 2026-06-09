import Foundation
import SwiftUI
import UIKit
import ProbeKit

// AudioUnitsModel backs the audio-units tab: it discovers installed AUv3s and,
// the moment a daemon is reachable on the LAN, automatically reads every unit's
// details (parameters/presets) and POSTs each record — no selecting, no manual
// "read & send". At the end of a sync it POSTs a scan report (every outcome,
// incl. failures) so nothing is lost in the UI.
//
// Connection state (host, healthz) lives in the shared Receiver, not here, so
// the audio-units and AUM-sessions tabs share one host; the view drives the
// auto-sync from the Receiver's reachability.

/// Per-row progress for a discovered audio unit.
enum AudioUnitRowStatus: Equatable {
    case idle
    case reading
    case sending
    case sent(params: Int, writable: Int)
    case empty            // read ok, but no parameters to map
    case failed(String)

    var text: String {
        switch self {
        case .idle: return ""
        case .reading: return "Reading…"
        case .sending: return "Sending…"
        case .sent(let p, let w): return "Synced · \(p) params · \(w) writable"
        case .empty: return "No mappable parameters"
        case .failed(let why): return "Failed · \(why)"
        }
    }

    var isError: Bool { if case .failed = self { return true }; return false }
    var isDone: Bool {
        switch self {
        case .sent, .empty: return true
        default: return false
        }
    }
    var isWorking: Bool {
        switch self {
        case .reading, .sending: return true
        default: return false
        }
    }
}

@MainActor
final class AudioUnitsModel: ObservableObject {
    @Published var units: [DiscoveredAudioUnit] = []
    @Published var statuses: [String: AudioUnitRowStatus] = [:]

    @Published var isBusy = false

    /// One-line summary of the last completed sync (sent/empty/failed tally).
    @Published var runSummary: String?

    /// Drives the inspector overlay: the id of the audio unit currently
    /// inspected, or nil when the sheet is dismissed.
    @Published var inspectedID: String?

    private var detailsByID: [String: AudioUnitDetails] = [:]

    /// The `host:port` we last completed an auto-sync to. Auto-sync runs once
    /// per discovered host rather than on every status republish.
    private var lastSyncedHost: String?

    /// Discover installed AUv3 units. Pure scan — no selection, no send.
    func refresh() {
        units = AudioUnitScanner.discover()
    }

    /// Auto-sync entry point, called whenever the daemon becomes reachable.
    /// Reads + POSTs every unit once per discovered host; a cheap no-op when
    /// already synced to this host or a sync is already in flight.
    func autoSync(client: DaemonClient, host: String) async {
        guard !isBusy, host != lastSyncedHost else { return }
        if units.isEmpty { refresh() }
        await syncAll(client: client)
        lastSyncedHost = host
    }

    /// Manual re-sync (the "resync" button): forget the synced host, rescan for
    /// newly installed units, and push everything again.
    func resync(client: DaemonClient?, host: String?) async {
        lastSyncedHost = nil
        refresh()
        guard let client, let host else { return }
        await syncAll(client: client)
        lastSyncedHost = host
    }

    /// Read each installed unit and POST its details, then POST a scan report.
    private func syncAll(client: DaemonClient) async {
        guard !units.isEmpty else { return }
        isBusy = true
        runSummary = nil
        defer { isBusy = false }

        var results: [ScanResult] = []
        for unit in units {
            statuses[unit.id] = .reading
            do {
                let details = try await AudioUnitScanner.readDetails(unit)
                detailsByID[unit.id] = details
                let params = details.parameters.count
                let isEmpty = params == 0

                if !isEmpty { statuses[unit.id] = .sending }
                let result = try await client.sendAudioUnit(details)

                statuses[unit.id] = isEmpty
                    ? .empty
                    : .sent(params: result.params, writable: result.writable)

                let sanitized = AudioUnitScanner.sanitizedCount(details)
                results.append(ScanResult(
                    id: details.fileID, name: unit.name, component: details.component,
                    status: isEmpty ? "empty" : "sent",
                    error: nil, params: result.params, writable: result.writable,
                    sanitized: sanitized == 0 ? nil : sanitized))
            } catch {
                statuses[unit.id] = .failed(error.localizedDescription)
                results.append(ScanResult(
                    id: unit.fileID, name: unit.name,
                    component: AudioUnitComponent(
                        type: unit.typeCode, subtype: "", manufacturer: "",
                        manufacturerName: unit.manufacturer.isEmpty ? nil : unit.manufacturer,
                        version: unit.version.isEmpty ? nil : unit.version),
                    status: "failed", error: error.localizedDescription,
                    params: 0, writable: 0, sanitized: nil))
            }
        }

        await finishRun(results: results, client: client)
    }

    /// Read a single audio unit locally and open the inspector — no data is sent.
    func inspect(_ unit: DiscoveredAudioUnit) async {
        // Already synced? Reuse the stashed details so inspect is instant.
        if detailsByID[unit.id] != nil {
            inspectedID = unit.id
            return
        }
        statuses[unit.id] = .reading
        do {
            let details = try await AudioUnitScanner.readDetails(unit)
            detailsByID[unit.id] = details
            let params = details.parameters.count
            statuses[unit.id] = params == 0 ? .empty : .idle
            inspectedID = unit.id
        } catch {
            statuses[unit.id] = .failed(error.localizedDescription)
        }
    }

    /// The stashed details for `id`, if the unit has been read.
    func details(_ id: String) -> AudioUnitDetails? { detailsByID[id] }

    /// POST the scan report (best-effort) and publish a run summary.
    private func finishRun(results: [ScanResult], client: DaemonClient) async {
        let sent = results.filter { $0.status == "sent" }.count
        let empty = results.filter { $0.status == "empty" }.count
        let failed = results.filter { $0.status == "failed" }.count
        runSummary = "\(results.count) total · \(sent) synced · \(empty) empty · \(failed) failed"

        let report = ScanReport(
            app: Self.appVersion,
            startedAt: Self.iso8601.string(from: Date()),
            device: ScanDevice(
                model: UIDevice.current.model,
                systemName: UIDevice.current.systemName,
                systemVersion: UIDevice.current.systemVersion),
            results: results)
        if (try? await client.sendReport(report)) != nil {
            runSummary? += " · report sent"
        }
    }

    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "auv3-probe \(v)"
    }

    private static let iso8601 = ISO8601DateFormatter()
}
