import Foundation
import SwiftUI

// ProbeModel is the ObservableObject backing the UI: it discovers installed
// AUv3s, tests connectivity to the receiver, probes the selected plugins, and
// POSTs each dump. Every probed dump is also stashed so the Save-to-Files
// fallback can export it when the receiver is unreachable.

/// Per-row progress for a discovered audio unit.
enum RowStatus: Equatable {
    case idle
    case probing
    case probed(params: Int, writable: Int)
    case sending
    case sent(params: Int, writable: Int)
    case failed(String)

    var text: String {
        switch self {
        case .idle: return ""
        case .probing: return "Probing…"
        case .probed(let p, let w): return "Probed: \(p) params, \(w) writable"
        case .sending: return "Sending…"
        case .sent(let p, let w): return "Sent: \(p) params, \(w) writable"
        case .failed(let why): return "Failed: \(why)"
        }
    }

    var isError: Bool { if case .failed = self { return true }; return false }
    var isDone: Bool { if case .sent = self { return true }; return false }
}

@MainActor
final class ProbeModel: ObservableObject {
    /// Receiver `host` or `host:port`, entered at runtime. Never persisted to
    /// git — the public-repo rule keeps endpoints out of committed code.
    @Published var host: String = ""

    @Published var units: [DiscoveredAudioUnit] = []
    @Published var selected: Set<String> = []
    @Published var statuses: [String: RowStatus] = [:]

    @Published var connectionOK = false
    @Published var connectionMessage: String?
    @Published var isBusy = false

    // Save-to-Files fallback state, driven by `.fileExporter`.
    @Published var isExporting = false
    @Published var exportDocument: ProbeJSONDocument?
    @Published var exportFilename = "probe.json"

    private var dumps: [String: ProbeDump] = [:]

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
    /// exported via Save-to-Files.
    func probeAndSendSelected() async {
        guard !selected.isEmpty else { return }
        let sender = ProbeSender(host: host)
        isBusy = true
        defer { isBusy = false }

        for unit in units where selected.contains(unit.id) {
            statuses[unit.id] = .probing
            do {
                let dump = try await AudioUnitProber.probe(unit)
                dumps[unit.id] = dump
                let params = dump.parameters.count
                let writable = dump.parameters.filter(\.writable).count

                guard let sender = sender else {
                    statuses[unit.id] = .probed(params: params, writable: writable)
                    continue
                }
                statuses[unit.id] = .sending
                let result = try await sender.send(dump)
                statuses[unit.id] = .sent(params: result.params, writable: result.writable)
            } catch {
                statuses[unit.id] = .failed(error.localizedDescription)
            }
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
}
