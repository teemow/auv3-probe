import Foundation
import SwiftUI
import ProbeKit

// AUMSyncEngine keeps the linked AUM folder (device) and mcp-midi-controller's
// staging dir (controller) identical — the two replicas of one logical session
// library (docs/aum-sessions-tab.md). It replaces the manual upload/download
// ferry and the old once-per-host push-only autoSync.
//
// Model: an index-based mirror. The engine persists a sync index
// (relative path → device mtime/size + controller modified/size at the last
// successful sync). Each cycle it enumerates the device folder, fetches the
// controller manifest (cheaply: GET /aum-session?rev=<last seen> answers 304
// when the staging dir is unchanged), and diffs both sides against the index:
//   - present on one side only            → copy to the other
//   - one side changed since last sync    → copy to the other (newest wins)
//   - BOTH sides changed                  → conflict badge, no silent overwrite
//   - deletions do NOT propagate in v1    → the surviving copy is restored
// Files move as verbatim bytes in both directions; the engine never re-encodes.
//
// Constraints baked in:
//   - The controller's upload route only accepts .aumproj (it validates the
//     session graph), so .aum_midimap files are pull-only: authored midimaps
//     flow controller → device, device-only midimaps simply stay device-only.
//   - Sync runs only while the app is foregrounded (iOS); the UI states this
//     plainly via `lastSynced` instead of pretending otherwise.
//
// Privacy: relative paths and filenames are private rig data — kept in
// UserDefaults and shown in-UI, never logged or committed.

/// Per-file sync state, shown as a row badge in the browser. `synced` is the
/// subtle default; everything else demands attention.
enum AUMFileSyncState: Equatable {
    case synced
    case pushing                 // device → controller copy in flight
    case pulling                 // controller → device copy in flight
    case conflict                // both sides changed; user picks a side
    case error(String)

    var isWorking: Bool { self == .pushing || self == .pulling }
}

/// What one sync cycle decided to do with a file (resolved from the index diff).
private enum SyncAction {
    case push(AUMFolderFile)
    case pull(AUMSessionEntry, updatesExisting: Bool)
    case conflict
    case none
}

/// One file that arrived or changed from the controller since the user last
/// looked — the "inbox" strip at the top of the browser root.
struct AUMInboxItem: Identifiable, Codable, Equatable {
    /// Relative path inside the AUM folder (== staging-relative path).
    let path: String
    /// False when the pull created the file, true when it overwrote one.
    let updated: Bool
    let date: Date

    var id: String { path }
    var filename: String { (path as NSString).lastPathComponent }
}

/// One side's fingerprint of a file at the last successful sync. The diff
/// compares current fingerprints against these to decide who changed.
private struct AUMSyncIndexEntry: Codable, Equatable {
    /// Device mtime (seconds since 1970) and size at last sync.
    var deviceModified: Double?
    var deviceBytes: Int
    /// Controller `modified` (RFC3339, verbatim from the manifest) and size
    /// at last sync. Compared as strings — only equality matters.
    var controllerModified: String
    var controllerBytes: Int
}

/// The header's one-line summary of where the library stands.
enum AUMSyncStatus: Equatable {
    case idle                    // never synced yet (no folder / no host)
    case syncing(String)         // "pulling 3…"
    case synced(files: Int, at: Date)
    case offline                 // controller unreachable — browsing device copy
    case failed(String)
}

@MainActor
final class AUMSyncEngine: ObservableObject {
    private static let indexKey = "aumSyncIndexV1"
    private static let inboxKey = "aumSyncInboxV1"

    /// Relative path → live sync state. Paths absent from the map are synced.
    @Published private(set) var states: [String: AUMFileSyncState] = [:]
    /// The device-folder listing the browser renders. After a clean cycle this
    /// IS the library (controller-only files have been pulled onto the device).
    @Published private(set) var deviceFiles: [AUMFolderFile] = []
    /// Files that arrived/changed from the controller since last viewed.
    @Published private(set) var inbox: [AUMInboxItem] = []
    @Published private(set) var status: AUMSyncStatus = .idle
    @Published private(set) var isSyncing = false
    /// Count of files currently staged on the controller (footer card).
    @Published private(set) var stagedCount: Int?
    /// The controller's staged entries from the last manifest. The browser
    /// itself renders `deviceFiles`; this backs the no-folder fallback list
    /// (browse/share staged files when no AUM folder is linked yet).
    @Published private(set) var controllerEntries: [AUMSessionEntry] = []

    /// The persisted index (relative path → both-side fingerprints).
    private var index: [String: AUMSyncIndexEntry]
    /// The last fetched manifest (staging rev + entries). In-memory only: the
    /// rev is just a poll short-circuit and a 304 means "reuse these entries",
    /// so the two only make sense together — and a fresh launch fetches once.
    private var lastManifest: AUMManifestSnapshot?
    /// Coalesces triggers: a kick during a running cycle queues one re-run
    /// with the freshest client/folder (the host may have changed mid-cycle).
    private var pendingKick: (client: DaemonClient?, folder: AUMFolderBookmark)?

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.indexKey),
           let decoded = try? JSONDecoder().decode([String: AUMSyncIndexEntry].self, from: data) {
            index = decoded
        } else {
            index = [:]
        }
        if let data = defaults.data(forKey: Self.inboxKey),
           let decoded = try? JSONDecoder().decode([AUMInboxItem].self, from: data) {
            inbox = decoded
        }
    }

    // MARK: - Triggers

    /// Run one sync cycle (or queue one if a cycle is already running). Safe to
    /// call from every trigger: reachability change, app foreground, tab
    /// appear, and the foreground poll — the rev short-circuit makes an idle
    /// cycle nearly free.
    func kick(client: DaemonClient?, folder: AUMFolderBookmark) {
        guard !isSyncing else {
            pendingKick = (client, folder)
            return
        }
        Task { await sync(client: client, folder: folder) }
    }

    /// Forget everything tied to the current library pairing. Call when the
    /// linked folder changes — fingerprints from the old folder must not be
    /// diffed against the new one.
    func reset() {
        index = [:]
        lastManifest = nil
        states = [:]
        inbox = []
        stagedCount = nil
        status = .idle
        persist()
    }

    // MARK: - One sync cycle

    func sync(client: DaemonClient?, folder: AUMFolderBookmark) async {
        guard !isSyncing else {
            pendingKick = (client, folder)
            return
        }
        isSyncing = true
        defer {
            isSyncing = false
            if let next = pendingKick {
                pendingKick = nil
                kick(client: next.client, folder: next.folder)
            }
        }

        // Device side first: the browser renders this even fully offline.
        refreshDeviceFiles(folder)

        guard let client = client else {
            status = folder.isBound ? .offline : .idle
            return
        }

        // Controller side, cheap when idle: a matching rev answers 304 and we
        // reuse the cached entries (a 304 without a cache cannot happen — we
        // only send a rev when we hold one).
        let entries: [AUMSessionEntry]
        do {
            if let snapshot = try await client.fetchAUMManifest(ifChangedFrom: lastManifest?.rev) {
                lastManifest = snapshot
            }
            entries = lastManifest?.entries ?? []
        } catch {
            status = .offline
            return
        }
        stagedCount = entries.count
        controllerEntries = entries
        persist()

        // No folder linked: nothing to mirror against — the staged listing
        // above is all the fallback UI needs.
        guard folder.isBound else {
            status = .idle
            return
        }

        // Diff and act.
        let plan = makePlan(deviceFiles: deviceFiles, entries: entries)
        var pushes = 0, pulls = 0, failures = 0
        for (path, action) in plan {
            switch action {
            case .none:
                if states[path]?.isWorking != true { states[path] = nil }
            case .conflict:
                states[path] = .conflict
            case .push(let file):
                states[path] = .pushing
                status = .syncing("pushing \(pushes + 1)…")
                if await push(file, client: client, folder: folder) { pushes += 1 } else { failures += 1 }
            case .pull(let entry, let updatesExisting):
                states[path] = .pulling
                status = .syncing("pulling \(pulls + 1)…")
                if await pull(entry, updatesExisting: updatesExisting, client: client, folder: folder) {
                    pulls += 1
                } else {
                    failures += 1
                }
            }
        }
        if pulls > 0 {
            refreshDeviceFiles(folder)
        }
        pruneIndex()
        persist()

        if failures > 0 {
            status = .failed("\(failures) file\(failures == 1 ? "" : "s") failed to sync")
        } else {
            status = .synced(files: deviceFiles.count, at: Date())
        }
    }

    /// Diff one snapshot of both sides against the index into per-file actions.
    private func makePlan(deviceFiles: [AUMFolderFile], entries: [AUMSessionEntry]) -> [(String, SyncAction)] {
        let device = Dictionary(uniqueKeysWithValues: deviceFiles.map { (normalize($0.relativePath), $0) })
        let controller = Dictionary(entries.map { (normalize($0.path), $0) }, uniquingKeysWith: { a, _ in a })

        var plan: [(String, SyncAction)] = []
        for path in Set(device.keys).union(controller.keys).sorted() {
            // A conflict the user has not resolved yet stays a conflict; the
            // diff must not silently flip it back to a copy.
            if states[path] == .conflict, device[path] != nil, controller[path] != nil {
                plan.append((path, .conflict))
                continue
            }
            plan.append((path, action(path: path, device: device[path], controller: controller[path])))
        }
        return plan
    }

    private func action(path: String, device: AUMFolderFile?, controller: AUMSessionEntry?) -> SyncAction {
        switch (device, controller) {
        case (nil, nil):
            return .none

        case (let file?, nil):
            // Device-only. Mirror it to the controller — also the v1 "deletion
            // does not propagate" path: a controller-side delete is restored
            // from the surviving device copy. Midimaps cannot be uploaded
            // (the controller's upload route validates a session graph), so
            // they stay device-only without complaint.
            if file.isMidiMap {
                index.removeValue(forKey: path)
                return .none
            }
            return .push(file)

        case (nil, let entry?):
            // Controller-only: a freshly authored/edited file (or a device-side
            // delete being restored — deletions don't propagate in v1).
            return .pull(entry, updatesExisting: false)

        case (let file?, let entry?):
            guard let idx = index[path] else {
                // Both sides exist but we never synced them (first run after
                // linking, or a fresh install). Equal sizes are taken as the
                // same file; different sizes are a conflict — bootstrapping
                // must not silently overwrite either side.
                if file.bytes == entry.bytes {
                    index[path] = fingerprint(file: file, entry: entry)
                    return .none
                }
                return .conflict
            }
            let deviceChanged = fingerprintChanged(file: file, against: idx)
            let controllerChanged = entry.modified != idx.controllerModified || entry.bytes != idx.controllerBytes
            switch (deviceChanged, controllerChanged) {
            case (false, false):
                return .none
            case (true, true):
                return .conflict
            case (true, false):
                return file.isMidiMap ? .none : .push(file)
            case (false, true):
                return .pull(entry, updatesExisting: true)
            }
        }
    }

    // MARK: - Copy primitives

    /// Upload one device file to the controller at its relative path,
    /// recording the new both-side fingerprint on success.
    private func push(_ file: AUMFolderFile, client: DaemonClient, folder: AUMFolderBookmark) async -> Bool {
        let path = normalize(file.relativePath)
        do {
            let data = try folder.read(file)
            _ = try await client.uploadAUMSession(
                data: data, filename: file.name, relativePath: file.relativePath, modified: file.modified)
            // The receiver preserves the modified time we sent (Chtimes), so
            // the manifest will echo the device mtime back — record exactly
            // what the next manifest fetch will show. Both byte counts come
            // from the data actually pushed: if the file changed between
            // enumeration and read, the next cycle re-detects it.
            index[path] = AUMSyncIndexEntry(
                deviceModified: file.modified?.timeIntervalSince1970,
                deviceBytes: data.count,
                controllerModified: file.modified.map { DaemonClient.rfc3339.string(from: $0) } ?? "",
                controllerBytes: data.count
            )
            states[path] = nil
            return true
        } catch {
            states[path] = .error(friendly(error))
            return false
        }
    }

    /// Download one controller file into the AUM folder at its relative path,
    /// recording the fingerprint on success. `noteInbox` queues an inbox item
    /// too — off for conflict resolution, where the user just chose this copy
    /// and an "updated from controller" arrival would only be noise.
    private func pull(_ entry: AUMSessionEntry, updatesExisting: Bool, noteInbox: Bool = true, client: DaemonClient, folder: AUMFolderBookmark) async -> Bool {
        let path = normalize(entry.path)
        do {
            let (data, _) = try await client.downloadAUMSession(path: entry.path)
            // Write at the entry's own relative location — never AUM's root —
            // keeping the device tree a true mirror of the staged tree.
            let dest = try folder.write(data: data, filename: entry.filename, subfolder: entry.subfolder)
            // Fingerprint the file as written (its fresh mtime), so the next
            // cycle sees it unchanged.
            index[path] = AUMSyncIndexEntry(
                deviceModified: folder.modificationDate(of: dest)?.timeIntervalSince1970,
                deviceBytes: data.count,
                controllerModified: entry.modified,
                controllerBytes: entry.bytes
            )
            states[path] = nil
            inbox.removeAll { $0.path == path }
            if noteInbox {
                inbox.insert(AUMInboxItem(path: path, updated: updatesExisting, date: Date()), at: 0)
            }
            return true
        } catch {
            states[path] = .error(friendly(error))
            return false
        }
    }

    // MARK: - Conflict resolution

    /// Resolve a conflict by copying the chosen side over the other. The row's
    /// "keep device / keep controller" buttons land here.
    func resolveConflict(path: String, keepDevice: Bool, client: DaemonClient?, folder: AUMFolderBookmark) async {
        guard let client = client else { return }
        let norm = normalize(path)
        if keepDevice {
            guard let file = deviceFiles.first(where: { normalize($0.relativePath) == norm }) else {
                states[norm] = .error("device copy disappeared — rescan")
                return
            }
            states[norm] = .pushing
            _ = await push(file, client: client, folder: folder)
        } else {
            guard let entry = lastManifest?.entries.first(where: { normalize($0.path) == norm }) else {
                states[norm] = .error("controller copy disappeared — refresh")
                return
            }
            states[norm] = .pulling
            if await pull(entry, updatesExisting: true, noteInbox: false, client: client, folder: folder) {
                refreshDeviceFiles(folder)
            }
        }
        persist()
    }

    // MARK: - View helpers

    /// The live sync state for a file's relative path (synced when untracked).
    func state(forPath path: String) -> AUMFileSyncState {
        states[normalize(path)] ?? .synced
    }

    /// True when `path` arrived/changed from the controller and has not been
    /// viewed or dismissed yet — drives the "new from controller" badge.
    func isInInbox(path: String) -> Bool {
        let norm = normalize(path)
        return inbox.contains { $0.path == norm }
    }

    /// True when any file under `prefix` ("" = anywhere, otherwise a folder's
    /// relative path) needs the *user*: a conflict, an error, or an unviewed
    /// inbox arrival. Routine in-flight copies don't count — the dot would
    /// just flicker on every sync. Drives the folder rows' attention dot.
    func needsAttention(under prefix: String) -> Bool {
        let inFolder: (String) -> Bool = { path in
            prefix.isEmpty || path == prefix || path.hasPrefix(prefix + "/")
        }
        let demandsUser: (AUMFileSyncState) -> Bool = { state in
            if case .error = state { return true }
            return state == .conflict
        }
        if states.contains(where: { inFolder($0.key) && demandsUser($0.value) }) { return true }
        return inbox.contains { inFolder($0.path) }
    }

    /// The total number of unresolved conflicts (header summary).
    var conflictCount: Int {
        states.values.filter { $0 == .conflict }.count
    }

    // MARK: - Inbox

    func dismissInbox(_ item: AUMInboxItem) {
        inbox.removeAll { $0.id == item.id }
        persist()
    }

    func clearInbox() {
        inbox = []
        persist()
    }

    // MARK: - Local bookkeeping

    /// Re-enumerate the device folder (used by the cycle and after external
    /// changes like a controller-side delete the user expects mirrored away).
    func refreshDeviceFiles(_ folder: AUMFolderBookmark) {
        guard folder.isBound else {
            deviceFiles = []
            return
        }
        deviceFiles = (try? folder.listFiles()) ?? []
    }

    /// Drop index entries (and stale error states) for files gone from BOTH
    /// sides, so explicit deletes don't leave ghosts behind.
    private func pruneIndex() {
        let known = Set(deviceFiles.map { normalize($0.relativePath) })
            .union((lastManifest?.entries ?? []).map { normalize($0.path) })
        index = index.filter { known.contains($0.key) }
        states = states.filter { known.contains($0.key) }
        inbox = inbox.filter { known.contains($0.path) }
    }

    private func fingerprint(file: AUMFolderFile, entry: AUMSessionEntry) -> AUMSyncIndexEntry {
        AUMSyncIndexEntry(
            deviceModified: file.modified?.timeIntervalSince1970,
            deviceBytes: file.bytes,
            controllerModified: entry.modified,
            controllerBytes: entry.bytes
        )
    }

    private func fingerprintChanged(file: AUMFolderFile, against idx: AUMSyncIndexEntry) -> Bool {
        if file.bytes != idx.deviceBytes { return true }
        // Compare mtimes at 1-second granularity: the wire format (RFC3339)
        // carries whole seconds, so finer differences are round-trip noise.
        let current = file.modified?.timeIntervalSince1970
        switch (current, idx.deviceModified) {
        case (nil, nil): return false
        case (let a?, let b?): return abs(a - b) >= 1
        default: return true
        }
    }

    /// AUMFolderFile.relativePath and AUMSessionEntry.path are both
    /// slash-separated already; normalize defensively so map keys line up.
    private func normalize(_ path: String) -> String {
        path.split(separator: "/").joined(separator: "/")
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(index) {
            defaults.set(data, forKey: Self.indexKey)
        }
        if let data = try? JSONEncoder().encode(inbox) {
            defaults.set(data, forKey: Self.inboxKey)
        }
    }

    private func friendly(_ error: Error) -> String {
        DaemonClient.friendlyMessage(for: error)
    }
}
