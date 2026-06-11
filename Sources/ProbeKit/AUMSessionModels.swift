import Foundation

// These types describe an AUM session (a `.aumproj` project): the summary
// mcp-midi-controller returns after an upload, the manifest of files it can
// return, and the parsed session map the inspector renders. The upload/manifest
// types mirror the Go wire contract (mcp-midi-controller, internal/aumreceiver);
// the JSON keys are the only contract between the two repos, so they are pinned
// here. The AUMSessionMap is produced *on-device* by AUMSessionParser (a Swift
// port of internal/aum's read model) — the app no longer depends on the daemon
// to understand a project.
//
// Privacy: titles and node component sets are a private rig snapshot. They are
// shown in-UI but never logged or committed.
//
// Lives in ProbeKit because DaemonClient (shared) returns these types; the
// app's AUMSessionParser constructs AUMSessionMap and friends, so the inits are
// public.

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

// MARK: - Parsed session map (for the inspector)

// AUMSessionMap and its children mirror the Go aum.SessionMap / ChannelInfo /
// NodeInfo / MappingInfo (internal/aum/session.go). They are produced on-device
// by AUMSessionParser from the binary plist; the Codable conformance is retained
// only for convenience (e.g. debug dumps), not because the daemon supplies them.

/// The flat, JSON view of one AUM session.
public struct AUMSessionMap: Codable, Equatable {
    public let version: Int
    /// Project tempo in BPM; the Go side omits it when zero.
    public let tempo: Double?
    public let channels: [ChannelInfo]
    public let mappings: [MappingInfo]
    /// MIDI routing edges (the AUM "MIDI" matrix: source → destination).
    public let routes: [MidiRoute]

    enum CodingKeys: String, CodingKey {
        case version, tempo, channels, mappings, routes
    }

    /// Built by the on-device parser (AUMSessionParser).
    public init(version: Int, tempo: Double?, channels: [ChannelInfo], mappings: [MappingInfo], routes: [MidiRoute]) {
        self.version = version
        self.tempo = tempo
        self.channels = channels
        self.mappings = mappings
        self.routes = routes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        tempo = try c.decodeIfPresent(Double.self, forKey: .tempo)
        channels = try c.decodeIfPresent([ChannelInfo].self, forKey: .channels) ?? []
        mappings = try c.decodeIfPresent([MappingInfo].self, forKey: .mappings) ?? []
        routes = try c.decodeIfPresent([MidiRoute].self, forKey: .routes) ?? []
    }
}

/// One MIDI routing edge from AUM's `midiMatrixState`: a source endpoint wired
/// to a destination endpoint (e.g. "nanoKEY Studio Bluetooth" → "MIDI Control").
/// Endpoint names are installation-specific (hardware on the rig).
public struct MidiRoute: Codable, Equatable {
    public let source: String
    public let sourceCategory: String
    public let destination: String
    public let destinationCategory: String

    enum CodingKeys: String, CodingKey {
        case source, sourceCategory, destination, destinationCategory
    }

    public init(source: String, sourceCategory: String, destination: String, destinationCategory: String) {
        self.source = source
        self.sourceCategory = sourceCategory
        self.destination = destination
        self.destinationCategory = destinationCategory
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        sourceCategory = try c.decodeIfPresent(String.self, forKey: .sourceCategory) ?? ""
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? ""
        destinationCategory = try c.decodeIfPresent(String.self, forKey: .destinationCategory) ?? ""
    }
}

/// One mixer strip in an AUMSessionMap.
public struct ChannelInfo: Codable, Equatable, Identifiable {
    public let index: Int
    /// Strip kind (e.g. AUM's channel/bus/master tokens).
    public let kind: String
    public let title: String?
    /// Fader level; the Go side uses a pointer so it can be absent.
    public let faderLevel: Double?
    public let muted: Bool
    public let soloed: Bool
    public let nodes: [NodeInfo]?

    public var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index, kind, title, faderLevel, muted, soloed, nodes
    }

    public init(index: Int, kind: String, title: String?, faderLevel: Double?,
                muted: Bool, soloed: Bool, nodes: [NodeInfo]?) {
        self.index = index
        self.kind = kind
        self.title = title
        self.faderLevel = faderLevel
        self.muted = muted
        self.soloed = soloed
        self.nodes = nodes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title)
        faderLevel = try c.decodeIfPresent(Double.self, forKey: .faderLevel)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        soloed = try c.decodeIfPresent(Bool.self, forKey: .soloed) ?? false
        nodes = try c.decodeIfPresent([NodeInfo].self, forKey: .nodes)
    }
}

/// One plugin/processing node on a channel. `component` is present only for AUv3
/// nodes (reusing the same AudioUnitComponent identity the audio-unit scan reads).
public struct NodeInfo: Codable, Equatable, Identifiable {
    /// Raw archive index of this node in the channel's node array — AUM's own
    /// `slot<S>` key, the same index midiCtrlState targets use (so a mapping's
    /// `…/slot<S>/…` aligns 1:1 with this value). NOTE: it is *storage/creation
    /// order, not signal-chain or visible-effect order*. AUM appends nodes as
    /// created, so a channel is typically `slot0` = source, `slot1` = the
    /// auto-created HW-output node, and an effect inserted as the *first visible
    /// effect slot* lands at `slot2` (after the output node). Resolve a node by
    /// its `component` / `archiveDescClass` identity — never assume `slot0` is
    /// the first effect. (Verified 2026-06-05: iSEM `slot0`, HWOutput `slot1`,
    /// ProbeAudioTap `slot2`.)
    public let slot: Int
    public let archiveDescClass: String?
    public let componentName: String?
    public let component: AudioUnitComponent?
    public let auMainParam: String?
    /// For internal-bus nodes (Bus source/dest/send): the AUM bus index.
    public let busIndex: Int?
    /// For hardware-I/O nodes (HW input/output): the hardware bus index.
    public let hwBusIndex: Int?
    /// For hardware-I/O nodes: mono/stereo channel select (0 = stereo).
    public let monoSelect: Int?

    public var id: Int { slot }

    enum CodingKeys: String, CodingKey {
        case slot, archiveDescClass, componentName, component, auMainParam
        case busIndex, hwBusIndex, monoSelect
    }

    public init(slot: Int, archiveDescClass: String?, componentName: String?,
                component: AudioUnitComponent?, auMainParam: String?,
                busIndex: Int?, hwBusIndex: Int?, monoSelect: Int?) {
        self.slot = slot
        self.archiveDescClass = archiveDescClass
        self.componentName = componentName
        self.component = component
        self.auMainParam = auMainParam
        self.busIndex = busIndex
        self.hwBusIndex = hwBusIndex
        self.monoSelect = monoSelect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slot = try c.decodeIfPresent(Int.self, forKey: .slot) ?? 0
        archiveDescClass = try c.decodeIfPresent(String.self, forKey: .archiveDescClass)
        componentName = try c.decodeIfPresent(String.self, forKey: .componentName)
        component = try c.decodeIfPresent(AudioUnitComponent.self, forKey: .component)
        auMainParam = try c.decodeIfPresent(String.self, forKey: .auMainParam)
        busIndex = try c.decodeIfPresent(Int.self, forKey: .busIndex)
        hwBusIndex = try c.decodeIfPresent(Int.self, forKey: .hwBusIndex)
        monoSelect = try c.decodeIfPresent(Int.self, forKey: .monoSelect)
    }

    /// True when this node is a hosted AUv3 plugin (vs. an AUM built-in).
    public var isPlugin: Bool { component != nil || (componentName?.isEmpty == false) }
}

/// One flattened mapping leaf in an AUMSessionMap (an assigned MIDI control).
///
/// `collection` is the path to the target's container (e.g.
/// `Channels/chan0/Channel controls`), `target` the leaf key. A preset-load
/// target is `_AUMNode:PresetLoadCtrl/<idx>:<presetNumber>:<name>`, where the
/// middle field is the AU preset's OWN number, NOT the MIDI program — the program
/// that fires it is this leaf's `data1` (verified 2026-06-05: `…/1:1:Damage_Bass`
/// fires on PC `data1=2`). The `slot<S>` segment is a raw archive index, not
/// visible-effect order (see `NodeInfo.slot`).
public struct MappingInfo: Codable, Equatable, Identifiable {
    public let collection: String
    public let target: String
    public let type: Int
    /// Human label for `type` (e.g. "CC", "Note", "PC", "PBEND", "CHPRS"),
    /// resolved against the leaf's on-disk encoding. Mirrors the Go side's
    /// `aum.Spec.TypeName()` / `MappingInfo.typeName`. Empty when unknown.
    public let typeName: String
    public let data1: Int
    /// Raw on-disk channel value. In BOTH encodings it is 0-based: stored 0 →
    /// MIDI/send channel 1, stored 15 → channel 16 (verified live 2026-06-05;
    /// AUM's picker "0 = OMNI" label does NOT match the stored value). The brain
    /// drives a leaf on `channel + 1`; the inspector renders `channel + 1` to
    /// match AUM. Mirrors Go `aum.Spec.Channel`.
    public let channel: Int
    public let min: Double
    public let max: Double
    public let autoToggle: Bool
    public let enabled: Bool

    /// Synthesized stable id for SwiftUI lists (mappings have no natural key).
    public var id: String { "\(collection)/\(target)/\(type)/\(data1)/\(channel)" }

    enum CodingKeys: String, CodingKey {
        case collection, target, type, typeName, data1, channel, min, max, autoToggle, enabled
    }

    public init(collection: String, target: String, type: Int, typeName: String = "",
                data1: Int, channel: Int, min: Double, max: Double,
                autoToggle: Bool, enabled: Bool) {
        self.collection = collection
        self.target = target
        self.type = type
        self.typeName = typeName.isEmpty ? MappingInfo.specStateTypeName(type: type, data1: data1) : typeName
        self.data1 = data1
        self.channel = channel
        self.min = min
        self.max = max
        self.autoToggle = autoToggle
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = try c.decodeIfPresent(String.self, forKey: .collection) ?? ""
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        type = try c.decodeIfPresent(Int.self, forKey: .type) ?? 0
        data1 = try c.decodeIfPresent(Int.self, forKey: .data1) ?? 0
        channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? 0
        min = try c.decodeIfPresent(Double.self, forKey: .min) ?? 0
        max = try c.decodeIfPresent(Double.self, forKey: .max) ?? 0
        autoToggle = try c.decodeIfPresent(Bool.self, forKey: .autoToggle) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        // Trust the daemon's label when present; otherwise derive it. Sessions
        // returned over the wire are version-13 (specState), so the specState
        // enum is the right fallback.
        let decoded = try c.decodeIfPresent(String.self, forKey: .typeName) ?? ""
        typeName = decoded.isEmpty ? MappingInfo.specStateTypeName(type: type, data1: data1) : decoded
    }

    /// Human label for a MIDI message type, correct for the on-disk leaf
    /// encoding. The specState (version 13) and packed (version 8/10) encodings
    /// use DIFFERENT type enums (e.g. a Note is specState type 1 but packed type
    /// 5), so the encoding must be supplied. Mirrors Go `aum.Spec.TypeName()`.
    ///
    /// specState codes confirmed 2026-06-05 from a hand-mapped probe capture:
    /// 0=CC, 1=Note, 2=Program Change, 3=Pitch Bend / Channel Pressure (split by
    /// `data1`: 0=PBEND, 1=CHPRS).
    public static func typeLabel(specState: Bool, type: Int, data1: Int) -> String {
        if specState {
            switch type {
            case 0: return "CC"
            case 1: return "Note"
            case 2: return "PC"
            case 3: return data1 == 1 ? "CHPRS" : "PBEND"
            default: return "type\(type)"
            }
        }
        switch type {
        case 0: return "CC"
        case 5: return "Note"
        case 4: return "value-placeholder"
        case 6: return "trigger-placeholder"
        default: return "type\(type)"
        }
    }

    static func specStateTypeName(type: Int, data1: Int) -> String {
        typeLabel(specState: true, type: type, data1: data1)
    }

    /// Compact "what fires this" label for the inspector, e.g. "CC 7", "Note 60",
    /// "PC 5"; Pitch Bend / Channel Pressure carry no number (their `data1` is a
    /// subtype selector, not a CC/note byte) so just the label is shown.
    public var valueLabel: String {
        if typeName == "PBEND" || typeName == "CHPRS" { return typeName }
        if typeName.isEmpty || typeName.hasPrefix("type") {
            return "type \(type) · data1 \(data1)"
        }
        return "\(typeName) \(data1)"
    }
}
