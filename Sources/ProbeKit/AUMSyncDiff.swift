import Foundation

// The diff of the session sync (docs/aum-sessions-tab.md, docs/aum-sync-report.md):
// what one cycle makes of each file, given the linked AUM folder's listing
// (device), the controller's manifest and the index of both sides' fingerprints
// at the last sync. It is pure, so it is tested without a folder or a daemon;
// AUMSyncEngine (in the app) does the listing, the copying and the persisting.
//
// Paths are the keys everywhere: slash-separated, relative to the AUM folder.

/// A file of the linked AUM folder, as one sync cycle sees it.
public struct AUMSyncDeviceFile: Equatable {
    public var path: String
    public var bytes: Int
    /// Modification time, seconds since 1970.
    public var modified: Double?
    /// A standalone `.aum_midimap`: pull-only, the controller's upload route
    /// takes sessions only.
    public var isMidiMap: Bool
    /// SHA-256 (hex) of the file's bytes, when the engine read them for this
    /// cycle (see `AUMSyncDiff.needsContentCheck`); nil otherwise.
    public var contentHash: String?

    public init(path: String, bytes: Int, modified: Double?, isMidiMap: Bool = false, contentHash: String? = nil) {
        self.path = path
        self.bytes = bytes
        self.modified = modified
        self.isMidiMap = isMidiMap
        self.contentHash = contentHash
    }
}

/// A file of the controller's manifest.
public struct AUMSyncControllerFile: Equatable {
    public var path: String
    public var bytes: Int
    /// The manifest's `modified` (RFC3339), verbatim. Only equality matters.
    public var modified: String

    public init(path: String, bytes: Int, modified: String) {
        self.path = path
        self.bytes = bytes
        self.modified = modified
    }
}

/// Both sides' fingerprints of a file at its last successful sync. The diff
/// compares the current fingerprints against these to decide who changed.
public struct AUMSyncIndexEntry: Codable, Equatable {
    /// Device mtime (seconds since 1970) and size at the last sync.
    public var deviceModified: Double?
    public var deviceBytes: Int
    /// Controller `modified` and size at the last sync.
    public var controllerModified: String
    public var controllerBytes: Int
    /// SHA-256 (hex) of the bytes both sides held at the last sync. nil in an
    /// index written before the app recorded it.
    public var contentHash: String?
    /// Whether a manifest has listed the path since the entry was written:
    /// false after an upload until the controller lists the file, nil in an
    /// index written before the app recorded it.
    public var controllerListed: Bool?

    public init(deviceModified: Double?, deviceBytes: Int, controllerModified: String, controllerBytes: Int,
                contentHash: String? = nil, controllerListed: Bool? = nil) {
        self.deviceModified = deviceModified
        self.deviceBytes = deviceBytes
        self.controllerModified = controllerModified
        self.controllerBytes = controllerBytes
        self.contentHash = contentHash
        self.controllerListed = controllerListed
    }
}

/// What a cycle does with one file.
public enum AUMSyncAction: Equatable {
    /// Nothing to copy.
    case none
    /// Copy the device's file to the controller.
    case push
    /// Copy the controller's file to the device; `updatesExisting` when the
    /// device has a file there already.
    case pull(updatesExisting: Bool)
    /// Both sides changed: copied neither way until a side is picked.
    case conflict
    /// The controller took the upload but does not list the file under this
    /// path; `alias` is the path it lists that differs only in case, if any.
    case unlisted(alias: String?)
}

/// The decision for one path: the action, and the index entry to keep for it
/// (nil: none).
public struct AUMSyncDecision: Equatable {
    public var action: AUMSyncAction
    public var index: AUMSyncIndexEntry?

    public init(_ action: AUMSyncAction, index: AUMSyncIndexEntry?) {
        self.action = action
        self.index = index
    }
}

/// One cycle's decisions, in path order, and the index after them.
public struct AUMSyncPlan {
    public var actions: [(path: String, action: AUMSyncAction)]
    public var index: [String: AUMSyncIndexEntry]
}

public enum AUMSyncDiff {
    /// Diff one snapshot of both sides against the index. `held` are the
    /// conflicts nobody has resolved yet.
    public static func plan(
        device: [AUMSyncDeviceFile],
        controller: [AUMSyncControllerFile],
        index: [String: AUMSyncIndexEntry],
        held: Set<String> = []
    ) -> AUMSyncPlan {
        let deviceByPath = Dictionary(device.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let controllerByPath = Dictionary(controller.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        // Where the controller keeps a path in another case (its file system
        // folds case, the iPad's does not).
        let controllerByFoldedPath = Dictionary(
            controller.map { ($0.path.lowercased(), $0.path) }, uniquingKeysWith: { a, _ in a })

        var plan = AUMSyncPlan(actions: [], index: [:])
        for path in Set(deviceByPath.keys).union(controllerByPath.keys).sorted() {
            let alias = controllerByFoldedPath[path.lowercased()].flatMap { $0 == path ? nil : $0 }
            let decision = decide(
                device: deviceByPath[path], controller: controllerByPath[path],
                index: index[path], held: held.contains(path), alias: alias)
            plan.actions.append((path, decision.action))
            plan.index[path] = decision.index
        }
        return plan
    }

    /// Decide one path. `alias` is a path the controller lists that differs
    /// from this one only in case.
    public static func decide(
        device: AUMSyncDeviceFile?,
        controller: AUMSyncControllerFile?,
        index: AUMSyncIndexEntry?,
        held: Bool = false,
        alias: String? = nil
    ) -> AUMSyncDecision {
        switch (device, controller) {
        case (nil, nil):
            return AUMSyncDecision(.none, index: nil)

        case (let file?, nil):
            // Device-only. Midimaps cannot be uploaded (the controller's
            // upload route validates a session graph), so they stay
            // device-only without complaint.
            if file.isMidiMap {
                return AUMSyncDecision(.none, index: nil)
            }
            // An upload the controller has not listed since: it keeps the file
            // under another path, or dropped it. Sending the same bytes again
            // changes nothing, so the file waits until it changes.
            if let idx = index, idx.controllerListed == false, !deviceChanged(file, since: idx) {
                return AUMSyncDecision(.unlisted(alias: alias), index: matching(idx, file))
            }
            // New on the device, or the v1 "deletion does not propagate" path:
            // a controller-side delete is restored from the surviving copy.
            return AUMSyncDecision(.push, index: index)

        case (nil, _?):
            // Controller-only: a freshly authored/edited file (or a device-side
            // delete being restored — deletions don't propagate in v1).
            return AUMSyncDecision(.pull(updatesExisting: false), index: index)

        case (let file?, let entry?):
            guard var idx = index else {
                // Both sides exist but we never synced them (first run after
                // linking, or a fresh install). Equal sizes are taken as the
                // same file; different sizes are a conflict — bootstrapping
                // must not silently overwrite either side.
                if file.bytes == entry.bytes {
                    return AUMSyncDecision(.none, index: AUMSyncIndexEntry(
                        deviceModified: file.modified, deviceBytes: file.bytes,
                        controllerModified: entry.modified, controllerBytes: entry.bytes,
                        contentHash: file.contentHash, controllerListed: true))
                }
                return AUMSyncDecision(.conflict, index: nil)
            }
            idx.controllerListed = true
            let deviceChanged = deviceChanged(file, since: idx)
            let controllerChanged = entry.modified != idx.controllerModified || entry.bytes != idx.controllerBytes
            if !deviceChanged {
                idx = matching(idx, file)
            }
            let action: AUMSyncAction
            switch (deviceChanged, controllerChanged) {
            case (false, false):
                return AUMSyncDecision(.none, index: idx)
            case (true, true):
                action = .conflict
            case (true, false):
                action = file.isMidiMap ? .none : .push
            case (false, true):
                action = .pull(updatesExisting: true)
            }
            // A conflict nobody has resolved yet is not silently turned into a
            // copy. (It ends above, once both sides match the index again.)
            return AUMSyncDecision(held && action != .none ? .conflict : action, index: idx)
        }
    }

    /// Whether the engine has to read the file's bytes before the diff can say
    /// if it changed: its date moved, its size did not, and the index knows the
    /// bytes of the last sync. The engine then sets `contentHash`.
    public static func needsContentCheck(_ file: AUMSyncDeviceFile, index: AUMSyncIndexEntry?) -> Bool {
        guard let idx = index, idx.contentHash != nil, file.contentHash == nil else { return false }
        return file.bytes == idx.deviceBytes && modifiedMoved(file.modified, idx.deviceModified)
    }

    /// A file's date alone does not make it changed: the app's own write, a
    /// restore or a copy all move it. With the size kept, the bytes decide
    /// where the index knows them.
    static func deviceChanged(_ file: AUMSyncDeviceFile, since idx: AUMSyncIndexEntry) -> Bool {
        if file.bytes != idx.deviceBytes { return true }
        guard modifiedMoved(file.modified, idx.deviceModified) else { return false }
        if let known = idx.contentHash, let now = file.contentHash {
            return known != now
        }
        return true
    }

    /// The entry of an unchanged file, with the date the file has now, so the
    /// next cycle need not read its bytes again.
    private static func matching(_ idx: AUMSyncIndexEntry, _ file: AUMSyncDeviceFile) -> AUMSyncIndexEntry {
        var idx = idx
        idx.deviceModified = file.modified
        return idx
    }

    /// Compare mtimes at 1-second granularity: the wire format (RFC3339)
    /// carries whole seconds, so finer differences are round-trip noise.
    public static func modifiedMoved(_ current: Double?, _ indexed: Double?) -> Bool {
        switch (current, indexed) {
        case (nil, nil): return false
        case (let a?, let b?): return abs(a - b) >= 1
        default: return true
        }
    }

    /// Relative paths are slash-separated on both sides already; normalize
    /// defensively so the keys line up.
    public static func normalize(_ path: String) -> String {
        path.split(separator: "/").joined(separator: "/")
    }
}
