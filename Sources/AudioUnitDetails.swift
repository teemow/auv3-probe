import Foundation

// These types describe an AUv3 audio unit (an "app"/plugin) and the details we
// read from it: its component identity, its parameters, and its presets. They
// mirror the Go device.ProbeDump / ProbeParam / ProbeComponent structs in the
// main mcp-midi-controller repo (internal/device/auv3probe.go). The JSON keys
// are the *only* contract between the two repos, so they are pinned here with
// explicit CodingKeys (camelCase). If the Go structs change, this mirror must
// change with them. (The Go names still say "Probe"; the Swift side names the
// concept directly — same wire format, clearer code.)

/// The AudioComponentDescription identity of an audio unit. type/subtype/
/// manufacturer are FourCharCode (`OSType`) values rendered as 4-character
/// strings (e.g. "aumu", "aufx"). manufacturerName / version are human-readable
/// extras read from `AVAudioUnitComponent` (optional; older records omit them).
/// Shared with the AUM session map, where a node references the same identity.
struct AudioUnitComponent: Codable, Equatable {
    var type: String
    var subtype: String
    var manufacturer: String
    var manufacturerName: String?
    var version: String?
    /// Human-readable component type (e.g. "Instrument", "Effect"), from
    /// `AVAudioUnitComponent.typeName`.
    var typeName: String?
    /// Component tags (e.g. "Effects", "Distortion"), from
    /// `AVAudioUnitComponent.allTagNames`. Omitted when empty to match Go.
    var tags: [String]?
}

/// One `AUParameter` read from an audio unit's `parameterTree`.
///
/// `min` / `max` / `value` are always finite: `AudioUnitScanner` sanitizes the
/// AU's non-finite values (±Inf, NaN — common for unbounded gain / log-scaled
/// params) to finite sentinels before this is encoded, because JSON (and Go's
/// encoding/json) cannot represent them. `nonFinite` records when that happened
/// so a sentinel is not mistaken for a real bound.
struct ParameterInfo: Codable, Equatable {
    var address: UInt64
    var keyPath: String
    var identifier: String
    var displayName: String
    var min: Double
    var max: Double
    var value: Double
    var unit: String
    /// Optional: the Go side decodes a JSON null into the empty string.
    var unitName: String?
    /// Optional: the Go side decodes a JSON null into a nil slice.
    var valueStrings: [String]?
    var writable: Bool
    var readable: Bool

    // Optional richer metadata (omitted when empty/false to match Go omitempty).
    var group: String?
    var flags: UInt32?
    var displayLogarithmic: Bool?
    var displayExponential: Bool?
    var isHighResolution: Bool?
    var isRampable: Bool?
    var isMeta: Bool?
    /// Addresses of parameters derived from this one
    /// (`AUParameter.dependentParameters`); a non-empty list marks a meta/macro
    /// control. Omitted when empty to match Go omitempty.
    var dependentParameters: [UInt64]?
    var nonFinite: String?

    enum CodingKeys: String, CodingKey {
        case address, keyPath, identifier, displayName
        case min, max, value, unit, unitName, valueStrings
        case writable, readable
        case group, flags, displayLogarithmic, displayExponential
        case isHighResolution, isRampable, isMeta, dependentParameters, nonFinite
    }
}

/// One preset exposed by an audio unit (name + number).
struct PresetInfo: Codable, Equatable {
    var number: Int
    var name: String
}

/// The full detail record for one AUv3 audio unit: its identity, every
/// parameter, and its presets. This is what the app uploads to the daemon and
/// renders in the inspector.
struct AudioUnitDetails: Codable, Equatable {
    var component: AudioUnitComponent
    var name: String
    var parameters: [ParameterInfo]

    // Optional richer metadata (omitted when empty to match Go omitempty).
    var shortName: String?
    var factoryPresets: [PresetInfo]?
    /// User-saved presets (`auAudioUnit.userPresets`). Recallable by Program
    /// Change like factory presets; their names are installation-specific so
    /// they only ever land in the gitignored state dir / user config.
    var userPresets: [PresetInfo]?

    /// Flattened `auAudioUnit.channelCapabilities` ([in, out] pairs, -1 = any).
    var channelCapabilities: [Int]?
    /// `auAudioUnit.latency` / `.tailTime` in seconds (omitted when 0).
    var latency: Double?
    var tailTime: Double?
    /// `auAudioUnit.supportsUserPresets`.
    var supportsUserPresets: Bool?

    enum CodingKeys: String, CodingKey {
        case component, name, parameters, shortName, factoryPresets, userPresets
        case channelCapabilities, latency, tailTime, supportsUserPresets
    }

    /// Encodes the details to stable, pretty JSON. `.sortedKeys` guarantees a
    /// deterministic ordering so the output diffs cleanly. `.convertToString` is
    /// a defensive backstop — the scanner already replaces non-finite values
    /// with finite sentinels, but this guarantees encoding never throws even if
    /// one slips through.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy =
            .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(self)
    }

    /// The sanitized id the daemon uses to name the staged `<id>.json` file
    /// (component subtype, falling back to the name). Mirrors the Go device
    /// ProbeID so the Save-to-Files fallback produces the same filename.
    var fileID: String {
        let base = component.subtype.isEmpty ? name : component.subtype
        return AudioUnitDetails.sanitizeID(base)
    }

    /// Lowercases and reduces a label to a filename/id-safe token: runs of
    /// non-alphanumeric characters collapse to a single underscore, with
    /// leading/trailing underscores trimmed. Mirrors the Go sanitizeName.
    static func sanitizeID(_ s: String) -> String {
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
struct ScanDevice: Codable, Equatable {
    var model: String?
    var systemName: String?
    var systemVersion: String?
}

/// The outcome for one audio unit in a scan.
struct ScanResult: Codable, Equatable {
    var id: String
    var name: String
    var component: AudioUnitComponent
    var status: String   // "sent" | "probed" | "empty" | "failed"
    var error: String?
    var params: Int
    var writable: Int
    var sanitized: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, component, status, error, params, writable, sanitized
    }
}

/// The full record of one scan run.
struct ScanReport: Codable, Equatable {
    var app: String?
    var startedAt: String?
    var device: ScanDevice?
    var results: [ScanResult]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// The daemon's JSON reply to a successful `POST /auv3-probe/diagnostics`.
struct DiagnosticsResult: Decodable {
    let total: Int
    let sent: Int
    let empty: Int
    let failed: Int
    let stored: String
}
