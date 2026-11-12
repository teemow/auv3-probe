import Foundation
import SwiftUI
import ProbeKit

// AUMSyncEngine keeps the linked AUM folder (device) and mcp-midi-controller's
// staging dir (controller) identical — the two replicas of one logical session
// library (docs/aum-sessions-tab.md). It replaces the manual upload/download
// ferry and the old once-per-host push-only autoSync.
//
// Model: an index-based mirror. The engine persists a sync index
// (relative path → both sides' fingerprints and the bytes' hash at the last
// successful sync). Each cycle it enumerates the device folder, fetches the
// controller manifest (cheaply: GET /aum-session?rev=<last seen> answers 304
// when the staging dir is unchanged), and diffs both sides against the index
// (AUMSyncDiff in ProbeKit, which has the rules and their tests):
//   - present on one side only            → copy to the other
//   - one side changed since last sync    → copy to the other (newest wins)
//   - BOTH sides changed                  → conflict badge, no silent overwrite
//   - deletions do NOT propagate in v1    → the surviving copy is restored
// Files move as verbatim bytes in both directions; the engine never re-encodes.
// After every cycle it tells the controller what it made of each file
// (docs/aum-sync-report.md).
//
// Constraints baked in:
//   - The controller's upload route only accepts .aumproj (it validates the
//     session graph), so .aum_midimap files are pull-only: authored midimaps
//     flow controller → device, device-only midimaps simply stay device-only.
//   - Sync runs only while the app is foregrounded (iOS); the UI states this
//     plainly via `lastSynced` instead of pretending otherwise.
//   - The engine never takes its own writes for changes: a file's date alone
//     does not make it changed (the bytes do), and a cycle looks at a file
//     again right before it copies, because its listing is as old as the cycle.
//
// Privacy: relative paths and filenames are private rig data — kept in
// UserDefaults, shown in-UI and reported to the controller the files are synced
// with, never logged or committed.

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
    /// How long a cycle copies by one plan before it makes a new one.
    private static let planLifetime: TimeInterval = 120

    /// Relative path → live sync state. Paths absent from the map are synced.
    @Published private(set) var states: [String: AUMFileSyncState] = [:]
    /// The device-folder listing the browser renders. After a clean cycle this
    /// IS the library (controller-only files have been pulled onto the device).
    @Published private(set) var deviceFiles: [AUMFolderFile] = []
    /// Files that arrived/changed from the controller since last viewed.
    @Published private(set) var inbox: [AUMInboxItem] = []
    @Published private(set) var status: AUMSyncStatus = .idle
    /// True while a cycle runs or a conflict is being resolved. The two never
    /// overlap: both change the index and copy files.
    @Published private(set) var isSyncing = false
    /// Count of files currently staged on the controller (footer card).
    @Published private(set) var stagedCount: Int?
    /// The controller's staged entries from the last manifest. The browser
    /// itself renders `deviceFiles`; this backs the no-folder fallback list
    /// (browse/share staged files when no AUM folder is linked yet).
    @Published private(set) var controllerEntries: [AUMSessionEntry] = []

    /// The audio units tab's progress, for the report to the controller. Set
    /// by the view that owns both.
    var audioUnitProgress: () -> AUMSyncReport.AudioUnits? = { nil }

    /// The persisted index (relative path → both-side fingerprints).
    private var index: [String: AUMSyncIndexEntry]
    /// The last fetched manifest (staging rev + entries). In-memory only: the
    /// rev is just a poll short-circuit and a 304 means "reuse these entries",
    /// so the two only make sense together — and a fresh launch fetches once.
    private var lastManifest: AUMManifestSnapshot?
    /// Set by an upload: the next cycle fetches the manifest whole instead of
    /// asking by rev, so it sees how the controller lists what it was sent.
    private var manifestIsStale = false
    /// Coalesces triggers: a kick during a running cycle queues one re-run
    /// with the freshest client/folder (the host may have changed mid-cycle).
    private var pendingKick: (client: DaemonClient?, folder: AUMFolderBookmark)?
    /// Conflict resolutions waiting for the running cycle to end.
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Uploads the controller refused (HTTP 4xx), with the file's stamp then.
    /// The same file is not sent again in every cycle. In memory only: a start
    /// tries once more.
    private var refused: [String: (bytes: Int, modified: Double?, text: String)] = [:]
    /// The daemon that has no route for the report (one from before it).
    private var reportRefusedBy: URL?
    /// Why the last listing of the AUM folder failed, nil when it did not.
    private var folderProblem: String?
    /// Bumped by `reset()`. A cycle that was waiting on the network when the
    /// folder was relinked must not copy into the new one.
    private var generation = 0

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
        generation += 1
        index = [:]
        lastManifest = nil
        manifestIsStale = false
        refused = [:]
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
        defer { finish() }
        await cycle(client: client, folder: folder)
    }

    /// End a cycle or a conflict's resolution. A resolution that waited goes
    /// first; a queued kick runs once nothing waits.
    private func finish() {
        isSyncing = false
        if !waiting.isEmpty {
            let resumed = waiting
            waiting = []
            resumed.forEach { $0.resume() }
        } else if let next = pendingKick {
            pendingKick = nil
            kick(client: next.client, folder: next.folder)
        }
    }

    private func cycle(client: DaemonClient?, folder: AUMFolderBookmark) async {
        let generation = self.generation

        // Device side first: the browser renders this even fully offline.
        let listed = refreshDeviceFiles(folder)

        guard let client = client else {
            status = folder.isBound ? .offline : .idle
            return
        }

        // Controller side, cheap when idle: a matching rev answers 304 and we
        // reuse the cached entries (a 304 without a cache cannot happen — we
        // only send a rev when we hold one).
        let entries: [AUMSessionEntry]
        do {
            let known = manifestIsStale ? nil : lastManifest?.rev
            if let snapshot = try await client.fetchAUMManifest(ifChangedFrom: known) {
                lastManifest = snapshot
                manifestIsStale = false
            }
            entries = lastManifest?.entries ?? []
        } catch {
            status = .offline
            return
        }
        guard generation == self.generation else { return }
        stagedCount = entries.count
        controllerEntries = entries

        // No folder linked: nothing to mirror against — the staged listing
        // above is all the fallback UI needs.
        guard folder.isBound else {
            status = .idle
            await report(to: client, error: AUMFolderError.noFolder.localizedDescription)
            return
        }
        // A folder that could not be listed is not an empty one: diffing
        // against nothing would fetch every controller file over the device's.
        guard listed else {
            let why = folderProblem ?? AUMFolderError.accessDenied.localizedDescription
            status = .failed(why)
            await report(to: client, error: why)
            return
        }

        // Diff.
        var listing: [String: AUMFolderFile] = [:]
        var device: [AUMSyncDeviceFile] = []
        for file in deviceFiles {
            let path = AUMSyncDiff.normalize(file.relativePath)
            guard listing[path] == nil else { continue }
            listing[path] = file
            device.append(syncFile(file, path: path, folder: folder))
        }
        var controller: [String: AUMSessionEntry] = [:]
        for entry in entries {
            let path = AUMSyncDiff.normalize(entry.path)
            if controller[path] == nil { controller[path] = entry }
        }
        let plan = AUMSyncDiff.plan(
            device: device,
            controller: controller.map { Self.controllerFile($0.value, path: $0.key) },
            index: index,
            held: Set(states.filter { $0.value == .conflict }.keys))
        if plan.index != index {
            index = plan.index
            persist()
        }
        let known = Set(plan.actions.map(\.path))
        inbox = inbox.filter { known.contains($0.path) }
        refused = refused.filter { known.contains($0.key) }

        var copies: [(path: String, action: AUMSyncAction)] = []
        var next: [String: AUMFileSyncState] = [:]
        for (path, action) in plan.actions {
            switch action {
            case .none:
                break
            case .conflict:
                next[path] = .conflict
            case .unlisted(let alias):
                next[path] = .error(Self.unlistedText(alias: alias))
            case .push:
                if let no = refused[path], let file = listing[path], no.bytes == file.bytes,
                   !AUMSyncDiff.modifiedMoved(file.modified?.timeIntervalSince1970, no.modified) {
                    // The controller refused this very file. It stays an
                    // error until the file changes.
                    next[path] = .error(no.text)
                } else {
                    next[path] = .pushing
                    copies.append((path, action))
                }
            case .pull:
                next[path] = .pulling
                copies.append((path, action))
            }
        }
        states = next

        // Copy. The controller hears what is queued before the first byte moves.
        if !copies.isEmpty {
            status = .syncing("\(copies.count) to copy…")
            await report(to: client)
        }
        var pushes = 0, pulls = 0
        let planned = Date()
        for copy in copies {
            guard generation == self.generation else { return }
            // A plan this old was made before the app was suspended, or the
            // copies before this one were slow. The controller's side may have
            // moved on since its manifest: start over with a fresh one. What
            // is left stays queued.
            if Date().timeIntervalSince(planned) > Self.planLifetime {
                if pendingKick == nil {
                    pendingKick = (client: client, folder: folder)
                }
                break
            }
            // The listing is as old as this cycle, and earlier copies took
            // their time. Look at the file again: if it is no longer what the
            // plan saw (AUM saved it meanwhile), leave it to the next cycle
            // rather than copy over a change. Its row and the report keep it
            // as queued until then.
            let entry = controller[copy.path]
            let relativePath = listing[copy.path]?.relativePath ?? entry?.path ?? copy.path
            let now = folder.file(atRelativePath: relativePath)
            let again = AUMSyncDiff.decide(
                device: now.map { syncFile($0, path: copy.path, folder: folder) },
                controller: entry.map { Self.controllerFile($0, path: copy.path) },
                index: index[copy.path])
            guard again.action == copy.action else { continue }
            switch copy.action {
            case .push:
                guard let file = now else { continue }
                status = .syncing("pushing \(pushes + 1)…")
                if await push(file, listed: entry != nil, client: client, folder: folder) { pushes += 1 }
            case .pull(let updatesExisting):
                guard let entry = entry else { continue }
                status = .syncing("pulling \(pulls + 1)…")
                if await pull(entry, replacing: now, updatesExisting: updatesExisting, client: client, folder: folder) {
                    pulls += 1
                }
            default:
                break
            }
        }
        guard generation == self.generation else { return }
        if pulls > 0 {
            refreshDeviceFiles(folder)
        }

        let failed = states.values.filter(\.isError).count
        if failed > 0 {
            status = .failed("\(failed) file\(failed == 1 ? "" : "s") failed to sync")
        } else {
            status = .synced(files: deviceFiles.count, at: Date())
        }
        await report(to: client)
    }

    /// The diff's view of a device file. Its bytes are read only when the diff
    /// needs them: the date moved while the size stayed.
    private func syncFile(_ file: AUMFolderFile, path: String, folder: AUMFolderBookmark) -> AUMSyncDeviceFile {
        var out = AUMSyncDeviceFile(
            path: path, bytes: file.bytes,
            modified: file.modified?.timeIntervalSince1970,
            isMidiMap: file.isMidiMap)
        if AUMSyncDiff.needsContentCheck(out, index: index[path]), let data = try? folder.read(file) {
            out.contentHash = ContentHash.sha256(data)
        }
        return out
    }

    private static func controllerFile(_ entry: AUMSessionEntry, path: String) -> AUMSyncControllerFile {
        AUMSyncControllerFile(path: path, bytes: entry.bytes, modified: entry.modified)
    }

    private static func unlistedText(alias: String?) -> String {
        if let alias = alias {
            return "the controller keeps this file as \"\(alias)\" — it cannot hold both names"
        }
        return "the controller took this file but does not list it — not sent again until it changes"
    }

    // MARK: - Copy primitives

    /// Upload one device file to the controller at its relative path,
    /// recording the new both-side fingerprint on success. `file` is the file
    /// as it is now, not as a listing saw it; `listed` says whether the
    /// controller's manifest has the path.
    private func push(_ file: AUMFolderFile, listed: Bool, client: DaemonClient, folder: AUMFolderBookmark) async -> Bool {
        let path = AUMSyncDiff.normalize(file.relativePath)
        let generation = self.generation
        do {
            let data = try folder.read(file)
            _ = try await client.uploadAUMSession(
                data: data, filename: file.name, relativePath: file.relativePath, modified: file.modified)
            guard generation == self.generation else { return false }
            // The receiver preserves the modified time we sent (Chtimes), so
            // the manifest will echo the device mtime back — record exactly
            // what the next manifest fetch will show. Both byte counts and the
            // hash come from the data actually pushed: if the file changed
            // after it was looked at, the next cycle re-detects it.
            index[path] = AUMSyncIndexEntry(
                deviceModified: file.modified?.timeIntervalSince1970,
                deviceBytes: data.count,
                controllerModified: file.modified.map { DaemonClient.rfc3339.string(from: $0) } ?? "",
                controllerBytes: data.count,
                contentHash: ContentHash.sha256(data),
                controllerListed: listed
            )
            manifestIsStale = true
            refused[path] = nil
            states[path] = nil
            persist()
            return true
        } catch {
            guard generation == self.generation else { return false }
            let text = friendly(error)
            if case DaemonError.notOK(let code, _) = error, (400..<500).contains(code) {
                refused[path] = (file.bytes, file.modified?.timeIntervalSince1970, text)
            }
            states[path] = .error(text)
            return false
        }
    }

    /// Download one controller file into the AUM folder at its relative path,
    /// recording the fingerprint on success. `current` is the device's file
    /// there now, if any. `noteInbox` queues an inbox item too — off for
    /// conflict resolution, where the user just chose this copy and an
    /// "updated from controller" arrival would only be noise.
    private func pull(_ entry: AUMSessionEntry, replacing current: AUMFolderFile?, updatesExisting: Bool,
                      noteInbox: Bool = true, client: DaemonClient, folder: AUMFolderBookmark) async -> Bool {
        let path = AUMSyncDiff.normalize(entry.path)
        let generation = self.generation
        do {
            let (data, _) = try await client.downloadAUMSession(path: entry.path)
            guard generation == self.generation else { return false }
            let hash = ContentHash.sha256(data)
            // The device has these very bytes already (the controller staged
            // them again, or they are the ones this app uploaded): leave the
            // file alone. AUM may have it open, and nothing arrived.
            if let current = current, current.bytes == data.count,
               let have = try? folder.read(current), have == data {
                index[path] = AUMSyncIndexEntry(
                    deviceModified: current.modified?.timeIntervalSince1970,
                    deviceBytes: data.count,
                    controllerModified: entry.modified,
                    controllerBytes: entry.bytes,
                    contentHash: hash,
                    controllerListed: true
                )
                states[path] = nil
                persist()
                return true
            }
            // Write at the entry's own relative location — never AUM's root —
            // keeping the device tree a true mirror of the staged tree.
            let dest = try folder.write(data: data, filename: entry.filename, subfolder: entry.subfolder)
            // Fingerprint the file as written, so the next cycle sees it
            // unchanged. The date is read by path: the URL just written
            // through would answer with the replaced file's (FileStamp).
            index[path] = AUMSyncIndexEntry(
                deviceModified: folder.stamp(of: dest)?.modified?.timeIntervalSince1970,
                deviceBytes: data.count,
                controllerModified: entry.modified,
                controllerBytes: entry.bytes,
                contentHash: hash,
                controllerListed: true
            )
            states[path] = nil
            inbox.removeAll { $0.path == path }
            if noteInbox {
                inbox.insert(AUMInboxItem(path: path, updated: updatesExisting, date: Date()), at: 0)
            }
            persist()
            return true
        } catch {
            guard generation == self.generation else { return false }
            states[path] = .error(friendly(error))
            return false
        }
    }

    // MARK: - Conflict resolution

    /// Resolve a conflict by copying the chosen side over the other. The row's
    /// "keep device / keep controller" buttons land here. It waits for a
    /// running cycle: the cycle's plan was made before the choice, and the two
    /// would copy the same file past each other.
    func resolveConflict(path: String, keepDevice: Bool, client: DaemonClient?, folder: AUMFolderBookmark) async {
        guard let client = client else { return }
        while isSyncing {
            await withCheckedContinuation { waiting.append($0) }
        }
        isSyncing = true
        defer { finish() }

        let norm = AUMSyncDiff.normalize(path)
        // The cycle that just ended may have found the two sides equal again.
        guard states[norm] == .conflict else { return }
        if keepDevice {
            guard let file = folder.file(atRelativePath: path) else {
                states[norm] = .error("device copy disappeared — rescan")
                return
            }
            states[norm] = .pushing
            _ = await push(file, listed: true, client: client, folder: folder)
        } else {
            guard let entry = lastManifest?.entries.first(where: { AUMSyncDiff.normalize($0.path) == norm }) else {
                states[norm] = .error("controller copy disappeared — refresh")
                return
            }
            states[norm] = .pulling
            let current = folder.file(atRelativePath: path)
            if await pull(entry, replacing: current, updatesExisting: true, noteInbox: false, client: client, folder: folder) {
                refreshDeviceFiles(folder)
            }
        }
        persist()
        await report(to: client)
    }

    // MARK: - Report to the controller

    /// Tell the controller what the sync made of each file (and how far the
    /// audio units' sync is). Best effort: a report that does not arrive is
    /// followed by the next cycle's.
    private func report(to client: DaemonClient, error: String? = nil) async {
        guard reportRefusedBy != client.baseURL else { return }
        let report = AUMSyncReport(
            app: Self.appVersion,
            rev: lastManifest?.rev ?? 0,
            states: states,
            index: index,
            error: error,
            audioUnits: audioUnitProgress())
        do {
            try await client.sendAUMSyncReport(report)
        } catch DaemonError.notOK(let code, _) where code == 404 || code == 405 {
            // A daemon from before the report. Ask again after the next start.
            reportRefusedBy = client.baseURL
        } catch {
        }
    }

    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "auv3-probe \(v)"
    }

    // MARK: - View helpers

    /// The live sync state for a file's relative path (synced when untracked).
    func state(forPath path: String) -> AUMFileSyncState {
        states[AUMSyncDiff.normalize(path)] ?? .synced
    }

    /// True when `path` arrived/changed from the controller and has not been
    /// viewed or dismissed yet — drives the "new from controller" badge.
    func isInInbox(path: String) -> Bool {
        let norm = AUMSyncDiff.normalize(path)
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
        if states.contains(where: { inFolder($0.key) && ($0.value.isError || $0.value == .conflict) }) {
            return true
        }
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

    /// Re-enumerate the device folder. False when a linked folder could not be
    /// listed; the browser then keeps showing the last listing.
    @discardableResult
    func refreshDeviceFiles(_ folder: AUMFolderBookmark) -> Bool {
        guard folder.isBound else {
            deviceFiles = []
            folderProblem = nil
            return true
        }
        do {
            deviceFiles = try folder.listFiles()
            folderProblem = nil
            return true
        } catch {
            folderProblem = error.localizedDescription
            return false
        }
    }

    /// Save the index and the inbox. Called after every copy, not once per
    /// cycle: iPadOS suspends the app the moment another one comes to the
    /// front (the controller opens AUM as soon as a session is fetched) and
    /// may drop it there. A fetch whose index entry was lost that way read as
    /// "both sides changed" at the next start.
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
