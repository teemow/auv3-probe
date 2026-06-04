import Foundation

// These types describe an AUv3 audio unit (an "app"/plugin) and the details we
// read from it: its component identity, its parameters, and its presets. They
// mirror the Go device.ProbeDump / ProbeParam / ProbeComponent structs in the
// main mcp-midi-controller repo (internal/device/auv3probe.go). The JSON keys
// are the *only* contract between the two repos, so they are pinned here with
// explicit CodingKeys (camelCase). If the Go structs change, this mirror must
// change with them. (The Go names still say "Probe"; the Swift side names the
// concept directly — same wire format, clearer code.)
//
// Lives in ProbeKit because DaemonClient (also shared) sends them; the app's
// AudioUnitScanner constructs them, so the inits are public.

/// The AudioComponentDescription identity of an audio unit. type/subtype/
/// manufacturer are FourCharCode (`OSType`) values rendered as 4-character
/// strings (e.g. "aumu", "aufx"). manufacturerName / version are human-readable
/// extras read from `AVAudioUnitComponent` (optional; older records omit them).
/// Shared with the AUM session map, where a node references the same identity.
public struct AudioUnitComponent: Codable, Equatable {
    public var type: String
    public var subtype: String
    public var manufacturer: String
    public var manufacturerName: String?
    public var version: String?
    /// Human-readable component type (e.g. "Instrument", "Effect"), from
    /// `AVAudioUnitComponent.typeName`.
    public var typeName: String?
    /// Component tags (e.g. "Effects", "Distortion"), from
    /// `AVAudioUnitComponent.allTagNames`. Omitted when empty to match Go.
    public var tags: [String]?

    public init(type: String, subtype: String, manufacturer: String,
                manufacturerName: String? = nil, version: String? = nil,
                typeName: String? = nil, tags: [String]? = nil) {
        self.type = type
        self.subtype = subtype
        self.manufacturer = manufacturer
        self.manufacturerName = manufacturerName
        self.version = version
        self.typeName = typeName
        self.tags = tags
    }
}

/// One `AUParameter` read from an audio unit's `parameterTree`.
///
/// `min` / `max` / `value` are always finite: `AudioUnitScanner` sanitizes the
/// AU's non-finite values (±Inf, NaN — common for unbounded gain / log-scaled
/// params) to finite sentinels before this is encoded, because JSON (and Go's
/// encoding/json) cannot represent them. `nonFinite` records when that happened
/// so a sentinel is not mistaken for a real bound.
public struct ParameterInfo: Codable, Equatable {
    public var address: UInt64
    public var keyPath: String
    public var identifier: String
    public var displayName: String
    public var min: Double
    public var max: Double
    public var value: Double
    public var unit: String
    /// Optional: the Go side decodes a JSON null into the empty string.
    public var unitName: String?
    /// Optional: the Go side decodes a JSON null into a nil slice.
    public var valueStrings: [String]?
    public var writable: Bool
    public var readable: Bool

    // Optional richer metadata (omitted when empty/false to match Go omitempty).
    public var group: String?
    public var flags: UInt32?
    public var displayLogarithmic: Bool?
    public var displayExponential: Bool?
    public var isHighResolution: Bool?
    public var isRampable: Bool?
    public var isMeta: Bool?
    /// Addresses of parameters derived from this one
    /// (`AUParameter.dependentParameters`); a non-empty list marks a meta/macro
    /// control. Omitted when empty to match Go omitempty.
    public var dependentParameters: [UInt64]?
    public var nonFinite: String?

    enum CodingKeys: String, CodingKey {
        case address, keyPath, identifier, displayName
        case min, max, value, unit, unitName, valueStrings
        case writable, readable
        case group, flags, displayLogarithmic, displayExponential
        case isHighResolution, isRampable, isMeta, dependentParameters, nonFinite
    }

    public init(address: UInt64, keyPath: String, identifier: String, displayName: String,
                min: Double, max: Double, value: Double, unit: String,
                unitName: String? = nil, valueStrings: [String]? = nil,
                writable: Bool, readable: Bool,
                group: String? = nil, flags: UInt32? = nil,
                displayLogarithmic: Bool? = nil, displayExponential: Bool? = nil,
                isHighResolution: Bool? = nil, isRampable: Bool? = nil, isMeta: Bool? = nil,
                dependentParameters: [UInt64]? = nil, nonFinite: String? = nil) {
        self.address = address
        self.keyPath = keyPath
        self.identifier = identifier
        self.displayName = displayName
        self.min = min
        self.max = max
        self.value = value
        self.unit = unit
        self.unitName = unitName
        self.valueStrings = valueStrings
        self.writable = writable
        self.readable = readable
        self.group = group
        self.flags = flags
        self.displayLogarithmic = displayLogarithmic
        self.displayExponential = displayExponential
        self.isHighResolution = isHighResolution
        self.isRampable = isRampable
        self.isMeta = isMeta
        self.dependentParameters = dependentParameters
        self.nonFinite = nonFinite
    }
}

/// One preset exposed by an audio unit (name + number).
public struct PresetInfo: Codable, Equatable {
    public var number: Int
    public var name: String

    public init(number: Int, name: String) {
        self.number = number
        self.name = name
    }
}

/// The full detail record for one AUv3 audio unit: its identity, every
/// parameter, and its presets. This is what the app uploads to the daemon and
/// renders in the inspector.
public struct AudioUnitDetails: Codable, Equatable {
    public var component: AudioUnitComponent
    public var name: String
    public var parameters: [ParameterInfo]

    // Optional richer metadata (omitted when empty to match Go omitempty).
    public var shortName: String?
    public var factoryPresets: [PresetInfo]?
    /// User-saved presets (`auAudioUnit.userPresets`). Recallable by Program
    /// Change like factory presets; their names are installation-specific so
    /// they only ever land in the gitignored state dir / user config.
    public var userPresets: [PresetInfo]?

    /// Flattened `auAudioUnit.channelCapabilities` ([in, out] pairs, -1 = any).
    public var channelCapabilities: [Int]?
    /// `auAudioUnit.latency` / `.tailTime` in seconds (omitted when 0).
    public var latency: Double?
    public var tailTime: Double?
    /// `auAudioUnit.supportsUserPresets`.
    public var supportsUserPresets: Bool?

    enum CodingKeys: String, CodingKey {
        case component, name, parameters, shortName, factoryPresets, userPresets
        case channelCapabilities, latency, tailTime, supportsUserPresets
    }

    public init(component: AudioUnitComponent, name: String, parameters: [ParameterInfo],
                shortName: String? = nil, factoryPresets: [PresetInfo]? = nil,
                userPresets: [PresetInfo]? = nil, channelCapabilities: [Int]? = nil,
                latency: Double? = nil, tailTime: Double? = nil,
                supportsUserPresets: Bool? = nil) {
        self.component = component
        self.name = name
        self.parameters = parameters
        self.shortName = shortName
        self.factoryPresets = factoryPresets
        self.userPresets = userPresets
        self.channelCapabilities = channelCapabilities
        self.latency = latency
        self.tailTime = tailTime
        self.supportsUserPresets = supportsUserPresets
    }

    /// Encodes the details to stable, pretty JSON. `.sortedKeys` guarantees a
    /// deterministic ordering so the output diffs cleanly. `.convertToString` is
    /// a defensive backstop — the scanner already replaces non-finite values
    /// with finite sentinels, but this guarantees encoding never throws even if
    /// one slips through.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy =
            .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(self)
    }

    /// The sanitized id the daemon uses to name the staged `<id>.json` file
    /// (component subtype, falling back to the name). Mirrors the Go device
    /// ProbeID so the Save-to-Files fallback produces the same filename.
    public var fileID: String {
        let base = component.subtype.isEmpty ? name : component.subtype
        return AudioUnitDetails.sanitizeID(base)
    }

    /// Lowercases and reduces a label to a filename/id-safe token: runs of
    /// non-alphanumeric characters collapse to a single underscore, with
    /// leading/trailing underscores trimmed. Mirrors the Go sanitizeName.
    public static func sanitizeID(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        var prevUnderscore = false
        for ch in lowered {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
                prevUnderscore = false
            } else if !prevUnderscore && !out.isEmpty {
                out.append("_")
                prevUnderscore = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}

// MARK: - Scan report

// A scan reads every selected audio unit and records the outcome of each one —
// including units that failed to instantiate or had no parameter tree, which
// never produce a details record. The report is POSTed to the daemon at the end
// of a run so no outcome is lost in the UI. Mirrors the Go device.ProbeReport /
// ProbeRunResult / ProbeRunDevice structs.

/// Non-identifying device context for a scan (no user-assigned device name, to
/// respect the public-repo / no-PII rule).
public struct ScanDevice: Codable, Equatable {
    public var model: String?
    public var systemName: String?
    public var systemVersion: String?

    public init(model: String? = nil, systemName: String? = nil, systemVersion: String? = nil) {
        self.model = model
        self.systemName = systemName
        self.systemVersion = systemVersion
    }
}

/// The outcome for one audio unit in a scan.
public struct ScanResult: Codable, Equatable {
    public var id: String
    public var name: String
    public var component: AudioUnitComponent
    public var status: String   // "sent" | "probed" | "empty" | "failed"
    public var error: String?
    public var params: Int
    public var writable: Int
    public var sanitized: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, component, status, error, params, writable, sanitized
    }

    public init(id: String, name: String, component: AudioUnitComponent, status: String,
                error: String? = nil, params: Int, writable: Int, sanitized: Int? = nil) {
        self.id = id
        self.name = name
        self.component = component
        self.status = status
        self.error = error
        self.params = params
        self.writable = writable
        self.sanitized = sanitized
    }
}

/// The full record of one scan run.
public struct ScanReport: Codable, Equatable {
    public var app: String?
    public var startedAt: String?
    public var device: ScanDevice?
    public var results: [ScanResult]

    public init(app: String? = nil, startedAt: String? = nil,
                device: ScanDevice? = nil, results: [ScanResult]) {
        self.app = app
        self.startedAt = startedAt
        self.device = device
        self.results = results
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// The daemon's JSON reply to a successful `POST /auv3-probe/diagnostics`.
public struct DiagnosticsResult: Decodable {
    public let total: Int
    public let sent: Int
    public let empty: Int
    public let failed: Int
    public let stored: String
}
