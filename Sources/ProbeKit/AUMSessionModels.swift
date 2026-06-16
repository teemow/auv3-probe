import Foundation

// These types are the AUM-session *wire contract* with mcp-midi-controller: the
// summary it returns after an upload and the manifest of files it can return.
// They mirror the Go wire contract (mcp-midi-controller, internal/aumreceiver);
// the JSON keys are the only contract between the two repos, so they are pinned
// here.
//
// The *parsed* read model (AUMSessionMap and friends, produced on-device from a
// `.aumproj`/`.aum_midimap` bplist) lives in the standalone `aum-session-swift`
// package (import AUMSession) — the app reads and inspects projects locally,
// without the daemon.
//
// Privacy: titles and paths are a private rig snapshot. They are shown in-UI but
// never logged or committed.
//
// Lives in ProbeKit because DaemonClient (shared) returns these types.

/// mcp-midi-controller's JSON reply to a successful `POST /aum-session`: a
/// compact, non-identifying summary of what the uploaded `.aumproj` decoded to.
/// Mirrors `aumreceiver.Result` (internal/aumreceiver/receiver.go).
public struct AUMSessionSummary: Codable, Equatable {
    /// Stable id the receiver assigned the staged session.
    public let id: String
    /// Staging-relative path the receiver wrote the file to (mirrors the
    /// file's location in the linked AUM folder). Empty from older daemons.
    public let path: String
    /// Human-readable session title decoded from the project (may be empty).
    public let title: String
    /// AUM project-format version.
    public let version: Int
    /// Number of mixer channels in the session.
    public let channels: Int
    /// Number of assigned MIDI mappings in the session.
    public let mappings: Int
    /// Size of the staged file in bytes.
    public let bytes: Int

    enum CodingKeys: String, CodingKey {
        case id, path, title, version, channels, mappings, bytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        channels = try c.decodeIfPresent(Int.self, forKey: .channels) ?? 0
        mappings = try c.decodeIfPresent(Int.self, forKey: .mappings) ?? 0
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
    }

    public init(id: String, path: String = "", title: String, version: Int, channels: Int, mappings: Int, bytes: Int) {
        self.id = id
        self.path = path
        self.title = title
        self.version = version
        self.channels = channels
        self.mappings = mappings
        self.bytes = bytes
    }
}

/// One file mcp-midi-controller holds that can be pulled back into AUM. `kind`
/// distinguishes a full session (`.aumproj`) from a standalone MIDI mapping
/// (`.aum_midimap`). The app's UI model; built from the receiver's manifest or
/// from a local file (one-off pick / linked folder).
public struct AUMSessionEntry: Equatable, Identifiable {
    public let id: String
    /// The bare on-disk filename (e.g. `set.aumproj`), the name the file keeps
    /// when written back into AUM.
    public let filename: String
    /// The file's staging-relative path on mcp-midi-controller, mirroring its
    /// location in the iPad's AUM folder (e.g. `Live sets/Set.aumproj`; equals
    /// `filename` for top-level files). Used to download/delete
    /// (`/aum-session/{file...}`) and to write a download back into the same
    /// AUM subfolder it came from.
    public let path: String
    /// `"session"` for a full `.aumproj`, `"midimap"` for a `.aum_midimap`.
    public let kind: String
    /// True when mcp-midi-controller generated this file (vs. a verbatim upload).
    public let generated: Bool
    /// File size in bytes.
    public let bytes: Int
    /// Last-modified timestamp (RFC3339 string from the receiver), or "".
    public let modified: String

    public init(id: String, filename: String, path: String = "", kind: String, generated: Bool, bytes: Int, modified: String) {
        self.id = id
        self.filename = filename
        self.path = path.isEmpty ? filename : path
        self.kind = kind
        self.generated = generated
        self.bytes = bytes
        self.modified = modified
    }

    /// Whether this entry is a standalone MIDI mapping (`.aum_midimap`).
    public var isMidiMap: Bool { kind == "midimap" }

    /// The AUM subfolder the file lives in ("" for the root), derived from
    /// `path`. This is where a write-back should land.
    public var subfolder: String {
        guard let idx = path.lastIndex(of: "/") else { return "" }
        return String(path[..<idx])
    }
}

/// mcp-midi-controller's `GET /aum-session` manifest: every stageable file the
/// app can pull back. Mirrors `aumreceiver.Manifest` / `ManifestEntry`
/// (internal/aumreceiver/receiver.go). Decoded here and mapped to
/// `AUMSessionEntry` for the UI.
public struct AUMSessionManifest: Decodable {
    public struct Entry: Decodable {
        public let id: String
        public let file: String
        public let path: String
        public let kind: String
        public let bytes: Int
        public let modified: String?

        enum CodingKeys: String, CodingKey {
            case id, file, path, kind, bytes, modified
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
            path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
            bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
            modified = try c.decodeIfPresent(String.self, forKey: .modified)
        }

        /// Map a manifest entry to the app's UI model. `path` falls back to the
        /// bare filename for manifests from older daemons.
        public var asEntry: AUMSessionEntry {
            AUMSessionEntry(
                id: id.isEmpty ? (path.isEmpty ? file : path) : id,
                filename: file,
                path: path,
                kind: kind,
                generated: false,
                bytes: bytes,
                modified: modified ?? ""
            )
        }
    }

    public let sessions: [Entry]
    /// The staging dir's monotonic change counter (0 from older daemons that
    /// don't send one). Bumped controller-side on every staging write —
    /// receiver uploads/deletes and MCP-tool author/edit/instrument/export —
    /// so the app can poll `GET /aum-session?rev=<last seen>` and skip all
    /// sync work on a 304.
    public let rev: Int64

    enum CodingKeys: String, CodingKey {
        case sessions, rev
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decodeIfPresent([Entry].self, forKey: .sessions) ?? []
        rev = try c.decodeIfPresent(Int64.self, forKey: .rev) ?? 0
    }
}
