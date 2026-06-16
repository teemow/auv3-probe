import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ProbeKit
import AUMSession

// AUMSessionsModel backs the AUM-sessions tab's user actions: inspect a file
// (on-device parse, no daemon), open a session in AUM via its Universal Link,
// and the explicit controller-side deletes. Everything that used to be the
// manual upload/download ferry — per-row uploads, "upload all", autoSync,
// save-into-folder — now lives in AUMSyncEngine, which keeps the linked AUM
// folder and the controller's staging dir mirrored automatically
// (docs/aum-sessions-tab.md).
//
// The share-sheet path survives only as the no-folder fallback: with no AUM
// folder linked the app cannot write files, so a staged session is downloaded
// to a temp file and handed to the share sheet ("Open in AUM" / "Save to
// Files…").
//
// Privacy: session titles/filenames and the parsed map carry private rig data.
// They are shown in-UI but never logged or committed.

/// An inspected AUM session: its manifest entry paired with the parsed map.
/// Drives `.sheet(item:)` (a plain map is not `Identifiable`).
struct InspectedAUMSession: Identifiable {
    let entry: AUMSessionEntry
    let map: AUMSessionMap
    var id: String { entry.id }
}

/// A staged file to hand to the share sheet, tagged with the entry it came
/// from so feedback can be resolved when sharing finishes.
struct AUMShareItem: Identifiable {
    let id: String      // the originating entry id
    let url: URL        // temp file to share
}

@MainActor
final class AUMSessionsModel: ObservableObject {
    // Inspect state.
    @Published var inspectingID: String?
    @Published var inspected: InspectedAUMSession?

    // One-line console feedback for the last user action (open/inspect/delete/
    // share). nil when the last action succeeded silently.
    @Published var actionMessage: String?

    // Write-back via share sheet (no-folder fallback only).
    @Published var shareItem: AUMShareItem?

    // Controller-side clear-staging progress.
    @Published var isClearing = false

    // MARK: - Inspect

    /// Handle the `.fileImporter` result: read the picked file under a
    /// security-scoped resource, parse it on-device, and open the inspector.
    func inspectPicked(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                actionMessage = friendly(error)
            }
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            actionMessage = nil
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
                actionMessage = friendly(error)
            }
        }
    }

    /// Parse a file from the linked AUM folder on-device and open the
    /// inspector. No daemon required.
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
            actionMessage = friendly(error)
        }
    }

    /// Inspect a file mcp-midi-controller holds (no-folder fallback): download
    /// its verbatim bytes and parse them on-device.
    func inspect(_ entry: AUMSessionEntry, client: DaemonClient?) async {
        guard let client = client else { return }
        inspectingID = entry.id
        defer { inspectingID = nil }
        do {
            let (data, _) = try await client.downloadAUMSession(path: entry.path)
            let map = try AUMSessionParser.parse(data: data, isMidiMap: entry.isMidiMap)
            inspected = InspectedAUMSession(entry: entry, map: map)
        } catch {
            actionMessage = friendly(error)
        }
    }

    // MARK: - Open in AUM

    /// Open a session that already lives in the linked AUM folder via AUM's
    /// Universal Link (the sync engine guarantees the on-device copy is
    /// current). AUM resolves the session by its folder-relative path, so this
    /// is a pure link open — no bytes move.
    func openInAUM(relativePath: String) async {
        guard let url = Self.aumOpenURL(relativePath: relativePath) else {
            actionMessage = "bad session name for the AUM link"
            return
        }
        actionMessage = nil
        let opened = await UIApplication.shared.open(url)
        if !opened {
            actionMessage = "AUM did not open (is it installed?)"
        }
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

    // MARK: - Share fallback (no folder linked)

    /// Download a staged file and hand it to the share sheet — the only way
    /// to move it toward AUM when no folder is linked.
    func share(_ entry: AUMSessionEntry, client: DaemonClient?) async {
        guard let client = client else { return }
        inspectingID = entry.id
        defer { inspectingID = nil }
        do {
            let (data, filename) = try await client.downloadAUMSession(path: entry.path)
            let url = try stageTemp(data: data, filename: filename)
            shareItem = AUMShareItem(id: entry.id, url: url)
        } catch {
            actionMessage = friendly(error)
        }
    }

    /// Resolve the share sheet's completion: clean up the temp file.
    func finishShare(completed: Bool) {
        if let url = shareItem?.url {
            try? FileManager.default.removeItem(at: url)
        }
        shareItem = nil
    }

    // MARK: - Delete (mcp-midi-controller only)

    /// Delete one staged file from mcp-midi-controller. This only removes the
    /// copy on the controller — never a file in the linked AUM folder / on the
    /// iPad (deleting AUM sessions on-device is intentionally not offered).
    /// Note the v1 mirror does not propagate deletions: if the file still
    /// exists on the device, the next sync cycle restores it.
    func deleteFromController(path: String, client: DaemonClient?) async {
        guard let client = client else { return }
        do {
            try await client.deleteAUMSession(path: path)
            actionMessage = nil
        } catch {
            actionMessage = friendly(error)
        }
    }

    /// Clear every staged file from mcp-midi-controller (controller-side only).
    func clearController(client: DaemonClient?) async {
        guard let client = client else { return }
        isClearing = true
        defer { isClearing = false }
        do {
            try await client.deleteAllAUMSessions()
            actionMessage = "cleared mcp-midi-controller."
        } catch {
            actionMessage = friendly(error)
        }
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

    private func friendly(_ error: Error) -> String {
        DaemonClient.friendlyMessage(for: error)
    }
}
