import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ProbeKit

// AudioUnitsModel backs the audio-units tab: it discovers installed AUv3s, reads
// the details (parameters/presets) of the selected ones, and POSTs each record
// to the daemon. Every read record is stashed so the Save-to-Files fallback can
// export it when the daemon is unreachable. At the end of a run it POSTs a scan
// report (every outcome, incl. failures) so nothing is lost in the UI.
//
// Connection state (host, healthz) lives in the shared Receiver, not here, so
// the audio-units and AUM-sessions tabs share one host. The daemon client is
// passed into the methods that need it (nil = no host, read-only/export-only).

/// Per-row progress for a discovered audio unit.
enum AudioUnitRowStatus: Equatable {
    case idle
    case reading
    case read(params: Int, writable: Int)
    case sending
    case sent(params: Int, writable: Int)
    case empty            // read ok, but no parameters to map
    case failed(String)

    var text: String {
        switch self {
        case .idle: return ""
        case .reading: return "Reading…"
        case .read(let p, let w): return "Read · \(p) params · \(w) writable"
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
        case .reading, .sending: return true
        default: return false
        }
    }
}

@MainActor
final class AudioUnitsModel: ObservableObject {
    @Published var units: [DiscoveredAudioUnit] = []
    @Published var selected: Set<String> = []
    @Published var statuses: [String: AudioUnitRowStatus] = [:]

    @Published var isBusy = false

    /// One-line summary of the last completed scan (sent/empty/failed tally).
    @Published var runSummary: String?

    /// Drives the inspector overlay: the id of the audio unit currently
    /// inspected, or nil when the sheet is dismissed.
    @Published var inspectedID: String?

    // Save-to-Files fallback state, driven by `.fileExporter`.
    @Published var isExporting = false
    @Published var exportDocument: AudioUnitDetailsDocument?
    @Published var exportFilename = "audio-unit.json"

    private var detailsByID: [String: AudioUnitDetails] = [:]

    func refresh() {
        units = AudioUnitScanner.discover()
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

    /// Read each selected audio unit and POST its details. The client is
    /// optional: with no host the units are still read and stashed so they can be
    /// exported via Save-to-Files. Every outcome is recorded and, if a client is
    /// configured, POSTed as a scan report at the end.
    func scanAndSendSelected(client: DaemonClient?) async {
        guard !selected.isEmpty else { return }
        isBusy = true
        runSummary = nil
        defer { isBusy = false }

        var results: [ScanResult] = []
        for unit in units where selected.contains(unit.id) {
            statuses[unit.id] = .reading
            do {
                let details = try await AudioUnitScanner.readDetails(unit)
                detailsByID[unit.id] = details
                let params = details.parameters.count
                let isEmpty = params == 0

                var counts = (params: params, writable: details.parameters.filter(\.writable).count)
                var sent = false
                if let client = client {
                    if !isEmpty { statuses[unit.id] = .sending }
                    let result = try await client.sendAudioUnit(details)
                    counts = (result.params, result.writable)
                    sent = true
                }

                statuses[unit.id] = isEmpty
                    ? .empty
                    : (sent ? .sent(params: counts.params, writable: counts.writable)
                            : .read(params: counts.params, writable: counts.writable))

                let sanitized = AudioUnitScanner.sanitizedCount(details)
                results.append(ScanResult(
                    id: details.fileID, name: unit.name, component: details.component,
                    status: isEmpty ? "empty" : (sent ? "sent" : "probed"),
                    error: nil, params: counts.params, writable: counts.writable,
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
        statuses[unit.id] = .reading
        do {
            let details = try await AudioUnitScanner.readDetails(unit)
            detailsByID[unit.id] = details
            let params = details.parameters.count
            statuses[unit.id] = params == 0
                ? .empty
                : .read(params: params, writable: details.parameters.filter(\.writable).count)
            inspectedID = unit.id
        } catch {
            statuses[unit.id] = .failed(error.localizedDescription)
        }
    }

    /// The stashed details for `id`, if the unit has been read.
    func details(_ id: String) -> AudioUnitDetails? { detailsByID[id] }

    /// POST the scan report (best-effort) and publish a run summary.
    private func finishRun(results: [ScanResult], client: DaemonClient?) async {
        let sent = results.filter { $0.status == "sent" }.count
        let empty = results.filter { $0.status == "empty" }.count
        let failed = results.filter { $0.status == "failed" }.count
        runSummary = "\(results.count) total · \(sent) sent · \(empty) empty · \(failed) failed"

        guard let client = client else { return }
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

    /// True when read details exist for the row, so Save-to-Files can run.
    func hasDetails(_ id: String) -> Bool { detailsByID[id] != nil }

    /// Prepare the `.fileExporter` to write the stashed details for `id`.
    func prepareExport(for id: String) {
        guard let details = detailsByID[id] else { return }
        do {
            exportDocument = try AudioUnitDetailsDocument(details: details)
            exportFilename = "\(details.fileID).json"
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

/// A JSON `FileDocument` for the Save-to-Files fallback (`.fileExporter`), used
/// when the daemon is unreachable so an audio unit's details can be transferred
/// manually.
struct AudioUnitDetailsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(details: AudioUnitDetails) throws {
        self.data = try details.encoded()
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
