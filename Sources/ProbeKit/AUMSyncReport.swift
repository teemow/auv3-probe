import Foundation

// What the app tells mcp-midi-controller of its two syncs: one small JSON
// document, `POST /aum-session/sync`, after every sync cycle of the sessions
// tab (docs/aum-sync-report.md has the format and when it is sent). Until this
// report the daemon saw only the app's manifest polls and downloads, and had to
// read the app's screen to learn why a file was not fetched.
//
// The JSON keys are the contract between the two repos, so they are pinned here.
//
// Privacy: the paths are private rig data. They go to the daemon the files are
// synced with and nowhere else; they are never logged.

/// Per-file sync state, shown as a row badge in the browser. `synced` is the
/// subtle default; everything else demands attention.
public enum AUMFileSyncState: Equatable {
    case synced
    case pushing                 // device → controller copy queued or in flight
    case pulling                 // controller → device copy queued or in flight
    case conflict                // both sides changed; user picks a side
    case error(String)

    public var isWorking: Bool { self == .pushing || self == .pulling }

    public var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

public struct AUMSyncReport: Codable, Equatable {
    /// The format's version, `v` in the document.
    public static let version = 1

    /// A file the sync could not copy, with the reason as the app shows it.
    public struct FileError: Codable, Equatable {
        public var path: String
        public var error: String

        public init(path: String, error: String) {
            self.path = path
            self.error = error
        }
    }

    /// The side a copy goes to.
    public enum Side: String, Codable {
        case device, controller
    }

    /// A copy that is queued or running.
    public struct Transfer: Codable, Equatable {
        public var path: String
        public var to: Side

        public init(path: String, to: Side) {
            self.path = path
            self.to = to
        }
    }

    /// The audio units tab's sync: every installed unit's parameters and
    /// presets, sent once per daemon.
    public struct AudioUnits: Codable, Equatable {
        public enum State: String, Codable {
            /// Units are installed that this daemon has not been sent, and no
            /// run is under way.
            case waiting
            case syncing
            /// Every installed unit was sent or failed for good.
            case done
        }

        public var state: State
        /// Installed units.
        public var total: Int
        /// Units the daemon holds (those without parameters included).
        public var synced: Int
        /// Units that could not be read or sent.
        public var failed: Int

        public init(state: State, total: Int, synced: Int, failed: Int) {
            self.state = state
            self.total = total
            self.synced = synced
            self.failed = failed
        }

        /// The progress of a tab that shows `synced` and `failed` of `total`
        /// units as dealt with, `syncing` while a run is under way.
        public init(total: Int, synced: Int, failed: Int, syncing: Bool) {
            let state: State
            if syncing {
                state = .syncing
            } else if total > 0, synced + failed >= total {
                state = .done
            } else {
                state = .waiting
            }
            self.init(state: state, total: total, synced: synced, failed: failed)
        }
    }

    public var v: Int
    /// The app and its version ("auv3-probe 0.4.0").
    public var app: String?
    /// When the report was made (RFC3339, UTC).
    public var at: String
    /// The staging rev of the manifest this cycle diffed against, 0 without
    /// one. A file staged at a later rev is not covered by this report.
    public var rev: Int64
    /// Files both sides hold as the same.
    public var synced: Int
    /// Files both sides changed since the last sync. They are copied neither
    /// way until a side is picked in the app.
    public var conflicts: [String]
    public var errors: [FileError]
    /// Copies queued or running. Empty in the report that ends a cycle.
    public var inFlight: [Transfer]
    /// Why the cycle mirrored nothing at all (no AUM folder linked, the folder
    /// cannot be read). Absent when it ran.
    public var error: String?
    public var audioUnits: AudioUnits?

    enum CodingKeys: String, CodingKey {
        case v, app, at, rev, synced, conflicts, errors
        case inFlight = "in_flight"
        case error
        case audioUnits = "audio_units"
    }

    public init(app: String? = nil, at: String, rev: Int64, synced: Int, conflicts: [String] = [],
                errors: [FileError] = [], inFlight: [Transfer] = [], error: String? = nil,
                audioUnits: AudioUnits? = nil) {
        self.v = Self.version
        self.app = app
        self.at = at
        self.rev = rev
        self.synced = synced
        self.conflicts = conflicts
        self.errors = errors
        self.inFlight = inFlight
        self.error = error
        self.audioUnits = audioUnits
    }

    /// The report of the engine's state: `states` are the files that are not
    /// in sync, `index` the files synced at some point (see `AUMSyncIndexEntry`).
    public init(app: String? = nil, at: Date = Date(), rev: Int64,
                states: [String: AUMFileSyncState], index: [String: AUMSyncIndexEntry],
                error: String? = nil, audioUnits: AudioUnits? = nil) {
        var conflicts: [String] = []
        var errors: [FileError] = []
        var inFlight: [Transfer] = []
        for (path, state) in states.sorted(by: { $0.key < $1.key }) {
            switch state {
            case .synced:
                break
            case .conflict:
                conflicts.append(path)
            case .error(let text):
                errors.append(FileError(path: path, error: text))
            case .pushing:
                inFlight.append(Transfer(path: path, to: .controller))
            case .pulling:
                inFlight.append(Transfer(path: path, to: .device))
            }
        }
        // In sync: synced once, listed by the controller, and nothing pending.
        let synced = index.filter { path, entry in
            entry.controllerListed != false && (states[path] ?? .synced) == .synced
        }.count
        self.init(app: app, at: Self.timestamp.string(from: at), rev: rev, synced: synced,
                  conflicts: conflicts, errors: errors, inFlight: inFlight,
                  error: error, audioUnits: audioUnits)
    }

    /// The document as sent. Keys are sorted so equal reports are equal bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
