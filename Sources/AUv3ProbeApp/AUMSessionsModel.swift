import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ProbeKit

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
    case uploading      // POSTing this file to mcp-midi-controller
    case uploaded       // staged on mcp-midi-controller
    case downloading
    case deleting       // removing this file from mcp-midi-controller
    case sharing        // share sheet presented for write-back
    case saved          // written into the AUM folder, or shared/saved out
    case failed(String)

    var text: String {
        switch self {
        case .idle: return ""
        case .uploading: return "Uploading…"
        case .uploaded: return "Uploaded to mcp-midi-controller"
        case .downloading: return "Downloading…"
        case .deleting: return "Deleting…"
        case .sharing: return "Choose where to save…"
        case .saved: return "Saved"
        case .failed(let why): return "Failed · \(why)"
        }
    }

    var isError: Bool { if case .failed = self { return true }; return false }
    var isDone: Bool { self == .saved || self == .uploaded }
    var isWorking: Bool { self == .downloading || self == .uploading || self == .deleting }
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
    // Shared "no controller host configured" copy: `noHostRow` lands on a file's
    // own row status; `noHostMessage` is the section-level prompt.
    static let noHostRow = "no host — set one in the top bar"
    static let noHostMessage = "enter a host (e.g. host:7800)"

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

    // MARK: - Auto-sync (the AUM-session sibling of AudioUnitsModel.autoSync)

    /// The `host:port` we last completed an auto-sync to. Auto-sync runs once
    /// per reachable host so a flapping connection does not re-upload the whole
    /// folder over and over.
    private var lastSyncedHost: String?

    /// Auto-sync entry point, called whenever the daemon becomes reachable:
    /// upload every `.aumproj` / `.aum_midimap` from the linked AUM folder with
    /// its folder-relative path, so the controller's staged tree mirrors the
    /// iPad's AUM folder exactly. A no-op when no folder is linked, we already
    /// synced to this host, or an upload is in flight. The host only counts as
    /// synced when at least one upload landed (or the folder was empty), so a
    /// fully-failed run is retried on the next reachability change.
    func autoSync(client: DaemonClient, host: String, folder: AUMFolderBookmark) async {
        guard !isUploading, host != lastSyncedHost, folder.isBound else { return }
        refreshFolder(folder)
        if folderFiles.isEmpty {
            lastSyncedHost = host
            return
        }
        let ok = await uploadAllFromFolder(folderFiles, client: client, folder: folder)
        if ok > 0 {
            lastSyncedHost = host
        }
    }

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

    /// Upload one file enumerated from the linked AUM folder. Progress and the
    /// outcome live on the file's own row (statuses[file.id]) so other rows stay
    /// interactive — the file itself remains on device and tappable to inspect.
    func uploadFromFolder(_ file: AUMFolderFile, client: DaemonClient?, folder: AUMFolderBookmark) async {
        guard let client = client else {
            statuses[file.id] = .failed(Self.noHostRow)
            return
        }
        let data: Data
        do {
            data = try folder.read(file)
        } catch {
            statuses[file.id] = .failed(friendly(error))
            return
        }
        statuses[file.id] = .uploading
        uploadMessage = nil
        do {
            uploadSummary = try await client.uploadAUMSession(
                data: data, filename: file.name, relativePath: file.relativePath, modified: file.modified)
            statuses[file.id] = .uploaded
            await refreshSessions(client: client)
        } catch {
            statuses[file.id] = .failed(friendly(error))
        }
    }

    /// Upload `files` enumerated from the linked AUM folder (the caller passes
    /// the currently visible/filtered set). Returns the number of files that
    /// uploaded successfully (per-file failures land on the row statuses).
    @discardableResult
    func uploadAllFromFolder(_ files: [AUMFolderFile], client: DaemonClient?, folder: AUMFolderBookmark) async -> Int {
        guard let client = client else {
            uploadMessage = Self.noHostMessage
            return 0
        }
        guard !files.isEmpty else { return 0 }

        isUploading = true
        uploadMessage = nil
        uploadInfo = nil
        uploadSummary = nil
        defer { isUploading = false }

        var ok = 0
        var failed = 0
        var last: AUMSessionSummary?
        for file in files {
            statuses[file.id] = .uploading
            do {
                let data = try folder.read(file)
                last = try await client.uploadAUMSession(
                    data: data, filename: file.name, relativePath: file.relativePath, modified: file.modified)
                statuses[file.id] = .uploaded
                ok += 1
            } catch {
                statuses[file.id] = .failed(friendly(error))
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
        return ok
    }

    // MARK: - Manifest

    /// Fetch mcp-midi-controller's `GET /aum-session` manifest.
    func refreshSessions(client: DaemonClient?) async {
        guard let client = client else {
            listMessage = Self.noHostMessage
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
                folderMessage = "no .aumproj / .aum_midimap files here or in any subfolder."
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
                path: file.relativePath,
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

    /// Inspect a file mcp-midi-controller holds: download its verbatim bytes and
    /// parse them on-device (same parser as local files — no `/map` endpoint).
    func inspect(_ entry: AUMSessionEntry, client: DaemonClient?) async {
        guard let client = client else {
            statuses[entry.id] = .failed(Self.noHostRow)
            return
        }
        inspectingID = entry.id
        defer { inspectingID = nil }
        do {
            let (data, _) = try await client.downloadAUMSession(path: entry.path)
            let map = try AUMSessionParser.parse(data: data, isMidiMap: entry.isMidiMap)
            inspected = InspectedAUMSession(entry: entry, map: map)
        } catch {
            statuses[entry.id] = .failed(friendly(error))
        }
    }

    // MARK: - Delete (mcp-midi-controller only)

    /// Delete one staged file from mcp-midi-controller. This only removes the
    /// copy on the controller — never a file in the linked AUM folder / on the
    /// iPad (deleting AUM sessions on-device is intentionally not offered).
    func deleteEntry(_ entry: AUMSessionEntry, client: DaemonClient?) async {
        guard let client = client else {
            statuses[entry.id] = .failed(Self.noHostRow)
            return
        }
        statuses[entry.id] = .deleting
        do {
            try await client.deleteAUMSession(path: entry.path)
            entries.removeAll { $0.id == entry.id }
            statuses[entry.id] = nil
        } catch {
            statuses[entry.id] = .failed(friendly(error))
        }
    }

    /// Clear every staged file from mcp-midi-controller (controller-side only).
    func clearSessions(client: DaemonClient?) async {
        guard let client = client else {
            listMessage = Self.noHostMessage
            return
        }
        isListing = true
        listMessage = nil
        defer { isListing = false }
        do {
            try await client.deleteAllAUMSessions()
            entries = []
            listMessage = "cleared mcp-midi-controller."
        } catch {
            listMessage = friendly(error)
        }
    }

    // MARK: - Download / write-back

    /// Distinct subfolders (relative paths) that already exist in the linked AUM
    /// tree, sorted for display. Used to let the user choose where a downloaded
    /// session lands instead of always dropping it in the root.
    var folderSubfolders: [String] {
        let subs = Set(folderFiles.map(\.subfolder).filter { !$0.isEmpty })
        return subs.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Download `entry`'s bytes and write them into a chosen `subfolder` of the
    /// linked AUM folder ("" = root). Used by the destination picker so the user
    /// controls where the session goes.
    func saveToFolder(_ entry: AUMSessionEntry, into subfolder: String, client: DaemonClient?, folder: AUMFolderBookmark) async {
        guard let client = client else {
            statuses[entry.id] = .failed(Self.noHostRow)
            return
        }
        statuses[entry.id] = .downloading
        guard let (data, filename) = await fetchBytes(entry, client: client) else { return }
        do {
            try folder.write(data: data, filename: filename, subfolder: subfolder)
            statuses[entry.id] = .saved
            refreshFolder(folder)
        } catch {
            statuses[entry.id] = .failed(friendly(error))
        }
    }

    /// Download `entry`'s verbatim bytes, resolving the filename the controller
    /// advertises (falling back to the entry's). On failure it sets the row's
    /// `.failed` status and returns nil, so callers can `guard let`.
    private func fetchBytes(_ entry: AUMSessionEntry, client: DaemonClient) async -> (data: Data, filename: String)? {
        do {
            let (data, resolved) = try await client.downloadAUMSession(path: entry.path)
            return (data, resolved.isEmpty ? entry.filename : resolved)
        } catch {
            statuses[entry.id] = .failed(friendly(error))
            return nil
        }
    }

    /// Download `entry`'s verbatim bytes and write them back toward AUM: straight
    /// into the linked folder when one is bound, otherwise via the share sheet.
    func download(_ entry: AUMSessionEntry, client: DaemonClient?, folder: AUMFolderBookmark) async {
        guard let client = client else {
            statuses[entry.id] = .failed(Self.noHostRow)
            return
        }
        statuses[entry.id] = .downloading
        guard let (data, filename) = await fetchBytes(entry, client: client) else { return }

        if folder.isBound {
            do {
                // The entry's staged path mirrors the file's original location in
                // the AUM tree, so write it back to exactly that spot: overwrite
                // the enumerated original in place when it still exists, otherwise
                // recreate it at the same relative path (subfolder included) —
                // never drop it in AUM's root unless it came from there.
                if let existing = folderFiles.first(where: { $0.relativePath == entry.path }) {
                    try folder.write(data: data, to: existing)
                } else {
                    try folder.write(data: data, filename: filename, subfolder: entry.subfolder)
                }
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

    // MARK: - Push & open (one-tap load into AUM)

    /// Download `entry`, write it into the linked AUM folder at its original
    /// relative path (subfolder included), then open AUM's Universal Link so
    /// AUM loads the session (applying its MIDI matrix). This is the one-tap
    /// "author → load" step of the agent loop. A linked folder is required
    /// because AUM resolves the session by its path inside its own folder —
    /// the link supports subfolders, so the session is loaded from (and stays
    /// in) the folder it came from instead of being duplicated into AUM's root.
    func pushAndOpen(_ entry: AUMSessionEntry, client: DaemonClient?, folder: AUMFolderBookmark) async {
        guard let client = client else {
            statuses[entry.id] = .failed(Self.noHostRow)
            return
        }
        guard folder.isBound else {
            statuses[entry.id] = .failed("link the AUM folder first (needed to load by name)")
            return
        }
        statuses[entry.id] = .downloading
        guard let (data, filename) = await fetchBytes(entry, client: client) else { return }
        // Build the link path from the *resolved* filename (Content-Disposition
        // may rename), so the file written below and the Universal Link always
        // refer to the same name.
        let relativePath = entry.subfolder.isEmpty ? filename : "\(entry.subfolder)/\(filename)"
        do {
            try folder.write(data: data, filename: filename, subfolder: entry.subfolder)
            refreshFolder(folder)
        } catch {
            statuses[entry.id] = .failed(friendly(error))
            return
        }
        guard let url = Self.aumOpenURL(relativePath: relativePath) else {
            statuses[entry.id] = .failed("bad session name for the AUM link")
            return
        }
        let opened = await UIApplication.shared.open(url)
        statuses[entry.id] = opened ? .saved : .failed("AUM did not open (is it installed?)")
    }

    /// Build AUM's Universal Link to open a session by its AUM-folder-relative
    /// path: `https://kymatica.com/aum/open/<sub/folder/name>.aumproj`. AUM
    /// supports subfolder segments in the link, so sessions living in nested
    /// folders open in place. Each segment is percent-encoded individually so a
    /// filename can never inject extra path segments.
    static func aumOpenURL(relativePath: String) -> URL? {
        let path = relativePath.isEmpty ? "session.aumproj" : relativePath
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let segments = path.split(separator: "/").map { seg -> String? in
            seg.addingPercentEncoding(withAllowedCharacters: allowed)
        }
        guard !segments.contains(nil) else { return nil }
        let encoded = segments.compactMap { $0 }.joined(separator: "/")
        return URL(string: "https://kymatica.com/aum/open/\(encoded)")
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
                return "mcp-midi-controller unreachable — check the host and that it's running"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
