import Foundation

// These types describe an AUM session (a `.aumproj` project) and the daemon's
// JSON envelopes about it: the summary returned after an upload, the manifest
// listing of files the daemon can return, and the parsed session map the
// inspector renders. They mirror the Go contract in the main mcp-midi-controller
// repo (internal/auv3receiver endpoints + internal/aum.SessionMap and friends).
// The JSON keys are the *only* contract between the two repos, so they are pinned
// here with explicit CodingKeys. If the Go structs change, this mirror must too.
//
// The app stays a thin byte-ferry: it never parses the .aumproj / .aum_midimap
// plist. The structured AUMSessionMap below comes from the daemon's /map endpoint
// (produced by the Go internal/aum library); the app only renders it.
//
// Privacy: titles and node component sets are a private rig snapshot. They are
// shown in-UI but never logged or committed.

/// The daemon's JSON reply to a successful `POST /aum-session`: a compact,
/// non-identifying summary of what the uploaded `.aumproj` decoded to.
struct AUMSessionSummary: Codable, Equatable {
    /// Stable id the daemon assigns the stored session; used to fetch generated
    /// files back via `GET /aum-session/{id}`.
    let id: String
    /// Human-readable session title decoded from the project (may be empty).
    let title: String
    /// AUM project-format version.
    let version: Int
    /// Number of mixer channels in the session.
    let channels: Int
    /// Number of plugin nodes across all channels.
    let nodes: Int
    /// Number of nodes that already carry a MIDI mapping.
    let mapped: Int

    enum CodingKeys: String, CodingKey {
        case id, title, version, channels, nodes, mapped
    }
}

/// One entry in the daemon's `GET /aum-sessions` manifest: a file the daemon
/// holds that can be pulled back into AUM. `kind` distinguishes a full session
/// (`.aumproj`) from a standalone MIDI mapping (`.aum_midimap`); `generated`
/// marks files the daemon produced (vs. ones it merely received).
struct AUMSessionEntry: Codable, Equatable, Identifiable {
    let id: String
    /// The filename to write back into AUM (e.g. `set.aumproj`).
    let filename: String
    /// `"session"` for a full `.aumproj`, `"midimap"` for a `.aum_midimap`.
    let kind: String
    /// True when the daemon generated this file (vs. a verbatim upload).
    let generated: Bool
    /// File size in bytes.
    let bytes: Int
    /// Last-modified timestamp (RFC3339 string from the daemon).
    let modified: String

    enum CodingKeys: String, CodingKey {
        case id, filename, kind, generated, bytes, modified
    }

    /// Whether this entry is a standalone MIDI mapping (`.aum_midimap`).
    var isMidiMap: Bool { kind == "midimap" }
}

// MARK: - Parsed session map (for the inspector)

// AUMSessionMap and its children mirror the Go aum.SessionMap / ChannelInfo /
// NodeInfo / MappingInfo (internal/aum/session.go). The daemon returns this from
// GET /aum-session/{id}/map; the app never parses the binary plist itself, so
// this is the only structured view it has of a project.

/// The flat, JSON view of one AUM session.
struct AUMSessionMap: Codable, Equatable {
    let version: Int
    /// Project tempo in BPM; the Go side omits it when zero.
    let tempo: Double?
    let channels: [ChannelInfo]
    let mappings: [MappingInfo]

    enum CodingKeys: String, CodingKey {
        case version, tempo, channels, mappings
    }

    /// Built by the on-device parser (AUMSessionParser).
    init(version: Int, tempo: Double?, channels: [ChannelInfo], mappings: [MappingInfo]) {
        self.version = version
        self.tempo = tempo
        self.channels = channels
        self.mappings = mappings
    }

    // Decode tolerantly: the daemon omits empty channels/mappings (Go omitempty).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        tempo = try c.decodeIfPresent(Double.self, forKey: .tempo)
        channels = try c.decodeIfPresent([ChannelInfo].self, forKey: .channels) ?? []
        mappings = try c.decodeIfPresent([MappingInfo].self, forKey: .mappings) ?? []
    }
}

/// One mixer strip in an AUMSessionMap.
struct ChannelInfo: Codable, Equatable, Identifiable {
    let index: Int
    /// Strip kind (e.g. AUM's channel/bus/master tokens).
    let kind: String
    let title: String?
    /// Fader level; the Go side uses a pointer so it can be absent.
    let faderLevel: Double?
    let muted: Bool
    let soloed: Bool
    let nodes: [NodeInfo]?

    var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index, kind, title, faderLevel, muted, soloed, nodes
    }

    init(index: Int, kind: String, title: String?, faderLevel: Double?,
         muted: Bool, soloed: Bool, nodes: [NodeInfo]?) {
        self.index = index
        self.kind = kind
        self.title = title
        self.faderLevel = faderLevel
        self.muted = muted
        self.soloed = soloed
        self.nodes = nodes
    }

    init(from decoder: Decoder) throws {
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
struct NodeInfo: Codable, Equatable, Identifiable {
    let slot: Int
    let archiveDescClass: String?
    let componentName: String?
    let component: AudioUnitComponent?
    let auMainParam: String?

    var id: Int { slot }

    enum CodingKeys: String, CodingKey {
        case slot, archiveDescClass, componentName, component, auMainParam
    }

    init(slot: Int, archiveDescClass: String?, componentName: String?,
         component: AudioUnitComponent?, auMainParam: String?) {
        self.slot = slot
        self.archiveDescClass = archiveDescClass
        self.componentName = componentName
        self.component = component
        self.auMainParam = auMainParam
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slot = try c.decodeIfPresent(Int.self, forKey: .slot) ?? 0
        archiveDescClass = try c.decodeIfPresent(String.self, forKey: .archiveDescClass)
        componentName = try c.decodeIfPresent(String.self, forKey: .componentName)
        component = try c.decodeIfPresent(AudioUnitComponent.self, forKey: .component)
        auMainParam = try c.decodeIfPresent(String.self, forKey: .auMainParam)
    }

    /// Best label for the node: component name, else its archive class.
    var label: String {
        if let name = componentName, !name.isEmpty { return name }
        if let cls = archiveDescClass, !cls.isEmpty { return cls }
        return "node \(slot)"
    }
}

/// One flattened mapping leaf in an AUMSessionMap (an assigned MIDI control).
struct MappingInfo: Codable, Equatable, Identifiable {
    let collection: String
    let target: String
    let type: Int
    let data1: Int
    let channel: Int
    let min: Double
    let max: Double
    let autoToggle: Bool
    let enabled: Bool

    /// Synthesized stable id for SwiftUI lists (mappings have no natural key).
    var id: String { "\(collection)/\(target)/\(type)/\(data1)/\(channel)" }

    enum CodingKeys: String, CodingKey {
        case collection, target, type, data1, channel, min, max, autoToggle, enabled
    }

    init(collection: String, target: String, type: Int, data1: Int, channel: Int,
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

    init(from decoder: Decoder) throws {
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
