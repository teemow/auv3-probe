import Foundation
import SwiftUI
import UIKit

// ProbeModel is the ObservableObject backing the UI: it discovers installed
// AUv3s, tests connectivity to the receiver, probes the selected plugins, and
// POSTs each dump. Every probed dump is also stashed so the Save-to-Files
// fallback can export it when the receiver is unreachable. At the end of a run
// it POSTs a diagnostics report (every outcome, including failures) so nothing
// is lost in the UI.

/// Per-row progress for a discovered audio unit.
enum RowStatus: Equatable {
    case idle
    case probing
    case probed(params: Int, writable: Int)
    case sending
    case sent(params: Int, writable: Int)
    case empty            // probed ok, but no parameters to map
    case failed(String)

    var text: String {
        switch self {
        case .idle: return ""
        case .probing: return "Probing…"
        case .probed(let p, let w): return "Probed · \(p) params · \(w) writable"
        case .sending: return "Sending…"
        case .sent(let p, let w): return "Sent · \(p) params · \(w) writable"
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
        case .probing, .sending: return true
        default: return false
        }
    }
}

@MainActor
final class ProbeModel: ObservableObject {
    private static let hostKey = "receiverHost"

    /// Receiver `host` or `host:port`. Persisted to UserDefaults so it is
    /// remembered across launches (the previous build cleared it every time).
    /// It is a local LAN address typed by the user, not committed to git, so
    /// persisting it on-device does not breach the public-repo rule.
    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: Self.hostKey) }
    }

    @Published var units: [DiscoveredAudioUnit] = []
    @Published var selected: Set<String> = []
    @Published var statuses: [String: RowStatus] = [:]

    @Published var connectionOK = false
    @Published var connectionMessage: String?
    @Published var isBusy = false

    /// One-line summary of the last completed run (sent/empty/failed tally).
    @Published var runSummary: String?

    // Save-to-Files fallback state, driven by `.fileExporter`.
    @Published var isExporting = false
    @Published var exportDocument: ProbeJSONDocument?
    @Published var exportFilename = "probe.json"

    private var dumps: [String: ProbeDump] = [:]

    init() {
        host = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""
    }

    var canSend: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }

    func refresh() {
        units = AudioUnitProber.discover()
        let valid = Set(units.map(\.id))
        selected.formIntersection(valid)
    }

    func toggle(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    func selectAll() { selected = Set(units.map(\.id)) }
    func selectNone() { selected.removeAll() }

    /// Test connectivity to the receiver via `GET /healthz`.
    func testConnection() async {
        guard let sender = ProbeSender(host: host) else {
            connectionOK = false
            connectionMessage = "Enter a host (e.g. host:7800)"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await sender.healthz()
            connectionOK = true
            connectionMessage = "Connected to \(sender.baseURL.host ?? "receiver")"
        } catch {
            connectionOK = false
            connectionMessage = error.localizedDescription
        }
    }

    /// Probe each selected plugin and POST the dump. The sender is optional:
    /// with no host the plugins are still probed and stashed so they can be
    /// exported via Save-to-Files. Every outcome is recorded and, if a sender is
    /// configured, POSTed as a diagnostics report at the end.
    func probeAndSendSelected() async {
        guard !selected.isEmpty else { return }
        let sender = ProbeSender(host: host)
        isBusy = true
        runSummary = nil
        defer { isBusy = false }

        var results: [ProbeRunResult] = []
        for unit in units where selected.contains(unit.id) {
            statuses[unit.id] = .probing
            do {
                let dump = try await AudioUnitProber.probe(unit)
                dumps[unit.id] = dump
                let params = dump.parameters.count
                let isEmpty = params == 0

                // Send when a receiver is configured; otherwise probe + stash so
                // the dump can be exported via Save-to-Files. Reported counts come
                // from the receiver when it answers, else from the local dump.
                var counts = (params: params, writable: dump.parameters.filter(\.writable).count)
                var sent = false
                if let sender = sender {
                    if !isEmpty { statuses[unit.id] = .sending }
                    let result = try await sender.send(dump)
                    counts = (result.params, result.writable)
                    sent = true
                }

                statuses[unit.id] = isEmpty
                    ? .empty
                    : (sent ? .sent(params: counts.params, writable: counts.writable)
                            : .probed(params: counts.params, writable: counts.writable))

                let sanitized = AudioUnitProber.sanitizedCount(dump)
                results.append(ProbeRunResult(
                    id: dump.probeID, name: unit.name, component: dump.component,
                    status: isEmpty ? "empty" : (sent ? "sent" : "probed"),
                    error: nil, params: counts.params, writable: counts.writable,
                    sanitized: sanitized == 0 ? nil : sanitized))
            } catch {
                statuses[unit.id] = .failed(error.localizedDescription)
                results.append(ProbeRunResult(
                    id: unit.probeID, name: unit.name,
                    component: ProbeComponent(
                        type: unit.typeCode, subtype: "", manufacturer: "",
                        manufacturerName: unit.manufacturer.isEmpty ? nil : unit.manufacturer,
                        version: unit.version.isEmpty ? nil : unit.version),
                    status: "failed", error: error.localizedDescription,
                    params: 0, writable: 0, sanitized: nil))
            }
        }

        await finishRun(results: results, sender: sender)
    }

    /// POST the diagnostics report (best-effort) and publish a run summary.
    private func finishRun(results: [ProbeRunResult], sender: ProbeSender?) async {
        let sent = results.filter { $0.status == "sent" }.count
        let empty = results.filter { $0.status == "empty" }.count
        let failed = results.filter { $0.status == "failed" }.count
        runSummary = "\(results.count) total · \(sent) sent · \(empty) empty · \(failed) failed"

        guard let sender = sender else { return }
        let report = ProbeReport(
            app: Self.appVersion,
            startedAt: Self.iso8601.string(from: Date()),
            device: ProbeRunDevice(
                model: UIDevice.current.model,
                systemName: UIDevice.current.systemName,
                systemVersion: UIDevice.current.systemVersion),
            results: results)
        // Best-effort: a failed report POST must not mask the run's own result.
        if (try? await sender.sendReport(report)) != nil {
            runSummary? += " · report sent"
        }
    }

    /// True when a probed dump exists for the row, so Save-to-Files can run.
    func hasDump(_ id: String) -> Bool { dumps[id] != nil }

    /// Prepare the `.fileExporter` to write the stashed dump for `id`.
    func prepareExport(for id: String) {
        guard let dump = dumps[id] else { return }
        do {
            exportDocument = try ProbeJSONDocument(dump: dump)
            exportFilename = "\(dump.probeID).json"
            isExporting = true
        } catch {
            statuses[id] = .failed(error.localizedDescription)
        }
    }

    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "auv3-probe \(v)"
    }

    private static let iso8601 = ISO8601DateFormatter()
}
