import Foundation
import SwiftUI
import UniformTypeIdentifiers

// AUMSessionsModel backs the AUM-sessions tab: it uploads .aumproj bytes to the
// daemon (verbatim), lists the files the daemon can return, writes a downloaded
// file back into AUM, and fetches the parsed AUMSessionMap for inspection.
//
// Uploads come from two sources: a one-off .fileImporter pick, or — when an AUM
// folder is linked (AUMFolderBookmark) — the files already in that folder, with
// one-tap "upload all". Write-back likewise prefers the linked folder (a direct,
// dialog-free write) and otherwise falls back to the share sheet.
//
// Connection state (host, healthz) lives in the shared Receiver and the folder
// bookmark in AUMFolderBookmark; both are passed into the methods that need them
// rather than owned here (matching the rest of the app).
//
// Privacy: session titles/filenames and the parsed map carry private rig data.
// They are shown in-UI but never logged or committed.

/// Per-row progress for a downloadable session/mapping entry.
enum AUMSessionRowStatus: Equatable {
    case idle
    case downloading
    case sharing        // share sheet presented for write-back
    case saved          // written into the AUM folder, or shared/saved out
    case failed(String)

    var text: String {
        switch self {
        case .idle: return ""
        case .downloading: return "Downloading…"
        case .sharing: return "Choose where to save…"
        case .saved: return "Saved"
        case .failed(let why): return "Failed · \(why)"
        }
    }

    var isError: Bool { if case .failed = self { return true }; return false }
    var isDone: Bool { self == .saved }
    var isWorking: Bool { self == .downloading }
}

/// An inspected AUM session: its manifest entry paired with the parsed map.
/// Drives `.sheet(item:)` (a plain map is not `Identifiable`).
struct InspectedAUMSession: Identifiable {
    let entry: AUMSessionEntry
    let map: AUMSessionMap
    var id: String { entry.id }
}

/// A staged file to hand to the share sheet, tagged with the row it came from so
/// its status can be resolved when sharing finishes.
struct AUMShareItem: Identifiable {
    let id: String      // the originating entry id
    let url: URL        // temp file to share
}

@MainActor
final class AUMSessionsModel: ObservableObject {
    // Picker state (one-off file pick).
    @Published var isImporting = false

    // Upload state.
    @Published var isUploading = false
    @Published var uploadSummary: AUMSessionSummary?
    @Published var uploadInfo: String?
    @Published var uploadMessage: String?

    // Manifest state.
    @Published var entries: [AUMSessionEntry] = []
    @Published var isListing = false
    @Published var listMessage: String?
    @Published var statuses: [String: AUMSessionRowStatus] = [:]

    // Inspect state.
    @Published var inspectingID: String?
    @Published var inspected: InspectedAUMSession?

    // Linked-folder enumeration state.
    @Published var folderFiles: [AUMFolderFile] = []
    @Published var isScanningFolder = false
    @Published var folderMessage: String?

    // Write-back via share sheet (used when no folder is linked).
    @Published var shareItem: AUMShareItem?

    // One-off "open a file" inspect feedback.
    @Published var openMessage: String?

    // MARK: - Inspect a picked file (no daemon)

    /// Handle the `.fileImporter` result: read the picked file under a
    /// security-scoped resource, parse it on-device, and open the inspector.
    func inspectPicked(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                openMessage = friendly(error)
            }
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            openMessage = nil
            do {
                let data = try Data(contentsOf: url)
                let isMidiMap = url.pathExtension.lowercased() == "aum_midimap"
                let map = try AUMSessionParser.parse(data: data, isMidiMap: isMidiMap)
                let entry = AUMSessionEntry(
                    id: url.path,
                    filename: url.lastPathComponent,
                    kind: isMidiMap ? "midimap" : "session",
                    generated: false,
                    bytes: data.count,
                    modified: ""
                )
                inspected = InspectedAUMSession(entry: entry, map: map)
            } catch {
                openMessage = friendly(error)
            }
        }
    }

    // MARK: - Upload (linked folder)

    /// Upload one file enumerated from the linked AUM folder.
    func uploadFromFolder(_ file: AUMFolderFile, client: DaemonClient?, folder: AUMFolderBookmark) async {
        guard let client = client else {
            uploadMessage = "enter a host (e.g. host:7800)"
            return
        }
        let data: Data
        do {
            data = try folder.read(file)
        } catch {
            uploadMessage = friendly(error)
            return
        }
        await send(data: data, filename: file.name, client: client)
    }

    /// Upload every file currently listed from the linked AUM folder.
    func uploadAllFromFolder(client: DaemonClient?, folder: AUMFolderBookmark) async {
        guard let client = client else {
            uploadMessage = "enter a host (e.g. host:7800)"
            return
        }
        let files = folderFiles
        guard !files.isEmpty else { return }

        isUploading = true
        uploadMessage = nil
        uploadInfo = nil
        uploadSummary = nil
        defer { isUploading = false }

        var ok = 0
        var failed = 0
        var last: AUMSessionSummary?
        for file in files {
            do {
                let data = try folder.read(file)
                last = try await client.uploadAUMSession(data: data, filename: file.name)
                ok += 1
            } catch {
                failed += 1
            }
        }
        uploadSummary = last
        if failed == 0 {
            uploadInfo = "uploaded \(ok) file\(ok == 1 ? "" : "s")."
        } else {
            uploadMessage = "uploaded \(ok), \(failed) failed."
        }
        await refreshSessions(client: client)
    }

    /// Shared upload tail: POST `data` and refresh the manifest.
    private func send(data: Data, filename: String, client: DaemonClient) async {
        isUploading = true
        uploadMessage = nil
        uploadInfo = nil
        uploadSummary = nil
        defer { isUploading = false }

        do {
            let summary = try await client.uploadAUMSession(data: data, filename: filename)
            uploadSummary = summary
            await refreshSessions(client: client)
        } catch {
            uploadMessage = friendly(error)
        }
    }

    // MARK: - Manifest

    /// Fetch the daemon's `GET /aum-sessions` manifest.
    func refreshSessions(client: DaemonClient?) async {
        guard let client = client else {
            listMessage = "enter a host (e.g. host:7800)"
            return
        }
        isListing = true
        listMessage = nil
        defer { isListing = false }
        do {
            let fetched = try await client.listAUMSessions()
            entries = fetched
            let valid = Set(fetched.map(\.id)).union(folderFiles.map(\.id))
            statuses = statuses.filter { valid.contains($0.key) }
            if fetched.isEmpty {
                listMessage = "no sessions available yet."
            }
        } catch {
            listMessage = friendly(error)
        }
    }

    // MARK: - Linked folder

    /// Re-enumerate the linked AUM folder's `.aumproj` / `.aum_midimap` files.
    func refreshFolder(_ folder: AUMFolderBookmark) {
        guard folder.isBound else {
            folderFiles = []
            folderMessage = nil
            return
        }
        isScanningFolder = true
        folderMessage = nil
        defer { isScanningFolder = false }
        do {
            folderFiles = try folder.listFiles()
            if folderFiles.isEmpty {
                folderMessage = "no .aumproj files in this folder."
            }
        } catch {
            folderFiles = []
            folderMessage = friendly(error)
        }
    }

    // MARK: - Inspect

    /// Parse a file from the linked AUM folder on-device and open the inspector.
    /// No daemon required.
    func inspectLocalFile(_ file: AUMFolderFile, folder: AUMFolderBookmark) async {
        inspectingID = file.id
        defer { inspectingID = nil }
        do {
            let data = try folder.read(file)
            let map = try AUMSessionParser.parse(data: data, isMidiMap: file.isMidiMap)
            let entry = AUMSessionEntry(
                id: file.id,
                filename: file.name,
                kind: file.isMidiMap ? "midimap" : "session",
                generated: false,
                bytes: file.bytes,
                modified: ""
            )
            inspected = InspectedAUMSession(entry: entry, map: map)
        } catch {
            statuses[file.id] = .failed(friendly(error))
        }
    }

    /// Fetch the parsed AUMSessionMap for a daemon `entry` and open the
    /// inspector (the daemon ferry path).
    func inspect(_ entry: AUMSessionEntry, client: DaemonClient?) async {
        guard let client = client else {
            statuses[entry.id] = .failed("no host")
            return
        }
        inspectingID = entry.id
        defer { inspectingID = nil }
        do {
            let map = try await client.fetchAUMSessionMap(id: entry.id)
            inspected = InspectedAUMSession(entry: entry, map: map)
        } catch {
            statuses[entry.id] = .failed(friendly(error))
        }
    }

    // MARK: - Download / write-back

    /// Download `entry`'s verbatim bytes and write them back toward AUM: straight
    /// into the linked folder when one is bound, otherwise via the share sheet.
    func download(_ entry: AUMSessionEntry, client: DaemonClient?, folder: AUMFolderBookmark) async {
        guard let client = client else {
            statuses[entry.id] = .failed("no host")
            return
        }
        statuses[entry.id] = .downloading
        let data: Data
        let filename: String
        do {
            let result = try await client.downloadAUMSession(id: entry.id)
            data = result.0
            filename = result.1.isEmpty ? entry.filename : result.1
        } catch {
            statuses[entry.id] = .failed(friendly(error))
            return
        }

        if folder.isBound {
            do {
                try folder.write(data: data, filename: filename)
                statuses[entry.id] = .saved
                refreshFolder(folder)
            } catch {
                statuses[entry.id] = .failed(friendly(error))
            }
            return
        }

        // No folder linked: stage a temp file and present the share sheet.
        do {
            let url = try stageTemp(data: data, filename: filename)
            shareItem = AUMShareItem(id: entry.id, url: url)
            statuses[entry.id] = .sharing
        } catch {
            statuses[entry.id] = .failed(friendly(error))
        }
    }

    /// Resolve the share sheet's completion: clean up the temp file and reflect
    /// the outcome on the originating row.
    func finishShare(completed: Bool) {
        let id = shareItem?.id
        if let url = shareItem?.url {
            try? FileManager.default.removeItem(at: url)
        }
        shareItem = nil
        guard let id = id else { return }
        statuses[id] = completed ? .saved : .idle
    }

    // MARK: - Helpers

    /// Stage `data` under `filename` in a temp dir so the share sheet has a real
    /// file URL (which yields "Open in AUM" + "Save to Files…").
    private func stageTemp(data: Data, filename: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aum-share", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = filename.isEmpty ? "session.aumproj" : filename
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Map transport errors to short, lowercase console messages; daemon and
    /// folder errors already carry friendly descriptions.
    private func friendly(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .timedOut, .dnsLookupFailed:
                return "daemon unreachable — check the host and that it's running"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
