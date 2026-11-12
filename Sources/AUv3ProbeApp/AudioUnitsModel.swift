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
// What a daemon was sent is remembered across starts (AudioUnitSyncRecord):
// iPadOS drops the app whenever another one has been in front for a while, and
// a start sends only the units the daemon does not hold yet — new ones, updated
// ones, those a run did not get to and those that failed. "resync" sends
// everything again.
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
    private static let recordKey = "audioUnitSyncRecordV1"

    @Published var units: [DiscoveredAudioUnit] = []
    @Published var statuses: [String: AudioUnitRowStatus] = [:]

    @Published var isBusy = false

    /// One-line summary of the last completed sync (sent/empty/failed tally).
    @Published var runSummary: String?

    /// Drives the inspector overlay: the id of the audio unit currently
    /// inspected, or nil when the sheet is dismissed.
    @Published var inspectedID: String?

    private var detailsByID: [String: AudioUnitDetails] = [:]

    /// The `host:port` an auto-sync ran against since the app started. It runs
    /// once per discovered host rather than on every status republish.
    private var lastSyncedHost: String?

    /// Which daemon the units were last sent to and what became of each, kept
    /// across starts.
    private var record: AudioUnitSyncRecord?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.recordKey) {
            record = try? JSONDecoder().decode(AudioUnitSyncRecord.self, from: data)
        }
    }

    /// Discover installed AUv3 units. Pure scan — no selection, no send.
    func refresh() {
        units = AudioUnitScanner.discover()
    }

    /// How far the sync to the daemon is, for the session sync's report
    /// (docs/aum-sync-report.md).
    var progress: AUMSyncReport.AudioUnits {
        var synced = 0, failed = 0
        for unit in units {
            guard let status = statuses[unit.id] else { continue }
            if status.isDone { synced += 1 } else if status.isError { failed += 1 }
        }
        return AUMSyncReport.AudioUnits(total: units.count, synced: synced, failed: failed, syncing: isBusy)
    }

    /// Auto-sync entry point, called whenever the daemon becomes reachable.
    /// Reads + POSTs the units this daemon has not been sent, once per
    /// discovered host; a cheap no-op when a sync is already in flight.
    func autoSync(client: DaemonClient, host: String) async {
        guard !isBusy, host != lastSyncedHost else { return }
        if units.isEmpty { refresh() }
        let pending = restoreStatuses(for: host)
        await sync(pending, client: client, host: host)
        lastSyncedHost = host
    }

    /// Manual re-sync (the "resync" button): forget what the daemon was sent,
    /// rescan for newly installed units, and push everything again.
    func resync(client: DaemonClient?, host: String?) async {
        lastSyncedHost = nil
        record = nil
        persistRecord()
        statuses = [:]
        refresh()
        guard let client, let host else { return }
        await sync(units, client: client, host: host)
        lastSyncedHost = host
    }

    /// Show what `host` was sent before, and return the units it does not
    /// hold: all of them for another daemon than the recorded one.
    private func restoreStatuses(for host: String) -> [DiscoveredAudioUnit] {
        record?.prune(to: units.map(Self.installed))
        var restored: [String: AudioUnitRowStatus] = [:]
        for unit in units {
            switch record?.outcome(of: Self.installed(unit), daemon: host) {
            case .sent(let params, let writable)?:
                restored[unit.id] = .sent(params: params, writable: writable)
            case .empty?:
                restored[unit.id] = .empty
            case .failed(let why)?:
                restored[unit.id] = .failed(why)
            case nil:
                break
            }
        }
        statuses = restored
        guard let record else { return units }
        let pending = Set(record.pending(units.map(Self.installed), daemon: host).map(\.id))
        return units.filter { pending.contains($0.id) }
    }

    /// Read each of `pending` and POST its details, then POST a scan report of
    /// the run. Every outcome goes into the record at once, so a run that
    /// iPadOS cuts short is taken up where it stopped.
    private func sync(_ pending: [DiscoveredAudioUnit], client: DaemonClient, host: String) async {
        guard !pending.isEmpty else {
            if !units.isEmpty { runSummary = tally() }
            return
        }
        isBusy = true
        runSummary = nil
        defer { isBusy = false }

        var results: [ScanResult] = []
        for unit in pending {
            statuses[unit.id] = .reading
            let details: AudioUnitDetails
            do {
                details = try await AudioUnitScanner.readDetails(unit)
            } catch {
                let why = error.localizedDescription
                statuses[unit.id] = .failed(why)
                note(unit, .failed(why), host: host)
                results.append(Self.failure(unit, id: unit.fileID, why))
                continue
            }
            detailsByID[unit.id] = details
            let isEmpty = details.parameters.isEmpty
            if !isEmpty { statuses[unit.id] = .sending }
            do {
                let result = try await client.sendAudioUnit(details)
                statuses[unit.id] = isEmpty
                    ? .empty
                    : .sent(params: result.params, writable: result.writable)
                note(unit, isEmpty ? .empty : .sent(params: result.params, writable: result.writable), host: host)

                let sanitized = AudioUnitScanner.sanitizedCount(details)
                results.append(ScanResult(
                    id: details.fileID, name: unit.name, component: details.component,
                    status: isEmpty ? "empty" : "sent",
                    error: nil, params: result.params, writable: result.writable,
                    sanitized: sanitized == 0 ? nil : sanitized))
            } catch {
                let why = error.localizedDescription
                statuses[unit.id] = .failed(why)
                // What the daemon refused is on record. What did not get
                // there (no connection) is not: nothing is known of it.
                if case DaemonError.notOK(let code, _) = error, (400..<500).contains(code) {
                    note(unit, .failed(why), host: host)
                }
                results.append(Self.failure(unit, id: details.fileID, why))
            }
        }

        await finishRun(results: results, client: client)
    }

    private static func installed(_ unit: DiscoveredAudioUnit) -> AudioUnitSyncRecord.Installed {
        AudioUnitSyncRecord.Installed(id: unit.id, version: unit.version)
    }

    private static func failure(_ unit: DiscoveredAudioUnit, id: String, _ why: String) -> ScanResult {
        ScanResult(
            id: id, name: unit.name, component: unit.component,
            status: "failed", error: why, params: 0, writable: 0, sanitized: nil)
    }

    private func note(_ unit: DiscoveredAudioUnit, _ outcome: AudioUnitSyncRecord.Outcome, host: String) {
        var next = record ?? AudioUnitSyncRecord(daemon: host)
        next.note(Self.installed(unit), outcome: outcome, daemon: host)
        record = next
        persistRecord()
    }

    private func persistRecord() {
        guard let record, let data = try? JSONEncoder().encode(record) else {
            UserDefaults.standard.removeObject(forKey: Self.recordKey)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.recordKey)
    }

    /// Read a single audio unit locally and open the inspector — no data is sent.
    func inspect(_ unit: DiscoveredAudioUnit) async {
        // Already synced? Reuse the stashed details so inspect is instant.
        if detailsByID[unit.id] != nil {
            inspectedID = unit.id
            return
        }
        // What the daemon was sent stays on the row: a unit synced in an
        // earlier start is only read again here, for the inspector.
        let before = statuses[unit.id]
        statuses[unit.id] = .reading
        do {
            let details = try await AudioUnitScanner.readDetails(unit)
            detailsByID[unit.id] = details
            if let before, before.isDone {
                statuses[unit.id] = before
            } else {
                statuses[unit.id] = details.parameters.isEmpty ? .empty : .idle
            }
            inspectedID = unit.id
        } catch {
            statuses[unit.id] = .failed(error.localizedDescription)
        }
    }

    /// The stashed details for `id`, if the unit has been read.
    func details(_ id: String) -> AudioUnitDetails? { detailsByID[id] }

    /// POST the scan report of this run (best-effort) and publish a summary.
    private func finishRun(results: [ScanResult], client: DaemonClient) async {
        runSummary = tally()

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

    /// The tally of all installed units, those synced in earlier starts
    /// included.
    private func tally() -> String {
        var sent = 0, empty = 0, failed = 0
        for unit in units {
            switch statuses[unit.id] {
            case .sent?: sent += 1
            case .empty?: empty += 1
            case .failed?: failed += 1
            default: break
            }
        }
        return "\(units.count) total · \(sent) synced · \(empty) empty · \(failed) failed"
    }

    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "auv3-probe \(v)"
    }

    private static let iso8601 = ISO8601DateFormatter()
}
