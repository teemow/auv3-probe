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
        case id, title, version, channels, mappings, bytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        channels = try c.decodeIfPresent(Int.self, forKey: .channels) ?? 0
        mappings = try c.decodeIfPresent(Int.self, forKey: .mappings) ?? 0
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
    }

    public init(id: String, title: String, version: Int, channels: Int, mappings: Int, bytes: Int) {
        self.id = id
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
    /// The on-disk filename, used both to download (`GET /aum-session/{file}`)
    /// and to write back into AUM (e.g. `set.aumproj`).
    public let filename: String
    /// `"session"` for a full `.aumproj`, `"midimap"` for a `.aum_midimap`.
    public let kind: String
    /// True when mcp-midi-controller generated this file (vs. a verbatim upload).
    public let generated: Bool
    /// File size in bytes.
    public let bytes: Int
    /// Last-modified timestamp (RFC3339 string from the receiver), or "".
    public let modified: String

    public init(id: String, filename: String, kind: String, generated: Bool, bytes: Int, modified: String) {
        self.id = id
        self.filename = filename
        self.kind = kind
        self.generated = generated
        self.bytes = bytes
        self.modified = modified
    }

    /// Whether this entry is a standalone MIDI mapping (`.aum_midimap`).
    public var isMidiMap: Bool { kind == "midimap" }
}

/// mcp-midi-controller's `GET /aum-session` manifest: every stageable file the
/// app can pull back. Mirrors `aumreceiver.Manifest` / `ManifestEntry`
/// (internal/aumreceiver/receiver.go). Decoded here and mapped to
/// `AUMSessionEntry` for the UI.
public struct AUMSessionManifest: Decodable {
    public struct Entry: Decodable {
        public let id: String
        public let file: String
        public let kind: String
        public let bytes: Int
        public let modified: String?

        enum CodingKeys: String, CodingKey {
            case id, file, kind, bytes, modified
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
            bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
            modified = try c.decodeIfPresent(String.self, forKey: .modified)
        }

        /// Map a manifest entry to the app's UI model.
        public var asEntry: AUMSessionEntry {
            AUMSessionEntry(
                id: id.isEmpty ? file : id,
                filename: file,
                kind: kind,
                generated: false,
                bytes: bytes,
                modified: modified ?? ""
            )
        }
    }

    public let sessions: [Entry]

    enum CodingKeys: String, CodingKey {
        case sessions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decodeIfPresent([Entry].self, forKey: .sessions) ?? []
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
public struct MappingInfo: Codable, Equatable, Identifiable {
    public let collection: String
    public let target: String
    public let type: Int
    public let data1: Int
    public let channel: Int
    public let min: Double
    public let max: Double
    public let autoToggle: Bool
    public let enabled: Bool

    /// Synthesized stable id for SwiftUI lists (mappings have no natural key).
    public var id: String { "\(collection)/\(target)/\(type)/\(data1)/\(channel)" }

    enum CodingKeys: String, CodingKey {
        case collection, target, type, data1, channel, min, max, autoToggle, enabled
    }

    public init(collection: String, target: String, type: Int, data1: Int, channel: Int,
                min: Double, max: Double, autoToggle: Bool, enabled: Bool) {
        self.collection = collection
        self.target = target
        self.type = type
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
    }
}
