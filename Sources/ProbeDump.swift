import Foundation

// ProbeDump mirrors the Go device.ProbeDump / ProbeParam / ProbeComponent
// structs in the main mcp-midi-controller repo (internal/device/auv3probe.go).
// The JSON keys are the *only* contract between the two repos, so they are
// pinned here with explicit CodingKeys (camelCase) even though Swift's default
// keying would already match the property names. If the Go structs change,
// this mirror must change with them.

/// The AudioComponentDescription the dump came from. type/subtype/manufacturer
/// are FourCharCode (`OSType`) values rendered as 4-character strings (e.g.
/// "aumu", "aufx"). manufacturerName / version are human-readable extras read
/// from `AVAudioUnitComponent` (optional; older dumps omit them).
struct ProbeComponent: Codable, Equatable {
    var type: String
    var subtype: String
    var manufacturer: String
    var manufacturerName: String?
    var version: String?
    /// Human-readable component type (e.g. "Instrument", "Effect"), from
    /// `AVAudioUnitComponent.typeName`. Optional richer metadata (added 2026-06).
    var typeName: String?
    /// Component tags (e.g. "Effects", "Distortion"), from
    /// `AVAudioUnitComponent.allTagNames` — useful for categorizing a plugin.
    /// Optional / omitted when empty to match Go omitempty.
    var tags: [String]?
}

/// One `AUParameter` as read from `auAudioUnit.parameterTree`.
///
/// `min` / `max` / `value` are always finite: `AudioUnitProber` sanitizes the
/// AU's non-finite values (±Inf, NaN — common for unbounded gain / log-scaled
/// params) to finite sentinels before this is encoded, because JSON (and Go's
/// encoding/json) cannot represent them. `nonFinite` records when that happened
/// so a sentinel is not mistaken for a real bound.
struct ProbeParam: Codable, Equatable {
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
    /// control. Optional / omitted when empty to match Go omitempty.
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

/// One factory preset exposed by the AudioUnit (name + number).
struct ProbePreset: Codable, Equatable {
    var number: Int
    var name: String
}

/// The full parameter-tree dump for one plugin.
struct ProbeDump: Codable, Equatable {
    var component: ProbeComponent
    var name: String
    var parameters: [ProbeParam]

    // Optional richer metadata (omitted when empty to match Go omitempty).
    var shortName: String?
    var factoryPresets: [ProbePreset]?
    /// User-saved presets (`auAudioUnit.userPresets`). Recallable by Program
    /// Change like factory presets; their names are installation-specific so
    /// they only ever land in the gitignored state dir / user config.
    var userPresets: [ProbePreset]?

    /// Flattened `auAudioUnit.channelCapabilities` ([in, out] pairs, -1 = any).
    var channelCapabilities: [Int]?
    /// `auAudioUnit.latency` / `.tailTime` in seconds (omitted when 0).
    var latency: Double?
    var tailTime: Double?
    /// `auAudioUnit.supportsUserPresets` (we never dump userPresets contents —
    /// they are user/installation state, see public-vs-private rule).
    var supportsUserPresets: Bool?

    enum CodingKeys: String, CodingKey {
        case component, name, parameters, shortName, factoryPresets, userPresets
        case channelCapabilities, latency, tailTime, supportsUserPresets
    }

    /// Encodes the dump to stable, pretty JSON. `.sortedKeys` guarantees a
    /// deterministic ordering so the output diffs cleanly; the receiver
    /// re-encodes anyway, but stable output also helps the Save-to-Files path.
    /// `.convertToString` is a defensive backstop — the prober already replaces
    /// non-finite values with finite sentinels, but this guarantees encoding
    /// never throws even if one slips through.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy =
            .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(self)
    }

    /// The sanitized id the receiver uses to name the staged `<id>.json` file
    /// (component subtype, falling back to the name). Mirrors device.ProbeID so
    /// the Save-to-Files fallback produces the same filename as the receiver.
    var probeID: String {
        let base = component.subtype.isEmpty ? name : component.subtype
        return ProbeDump.sanitizeID(base)
    }

    /// Lowercases and reduces a label to a filename/id-safe token: runs of
    /// non-alphanumeric characters collapse to a single underscore, with
    /// leading/trailing underscores trimmed. Mirrors device.sanitizeName.
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

// MARK: - Diagnostics report

// ProbeReport mirrors the Go device.ProbeReport / ProbeRunResult /
// ProbeRunDevice structs. It is POSTed to /auv3-probe/diagnostics at the end of
// a probe run so every outcome — including plugins that failed to instantiate
// or had no parameter tree, which never produce a dump — is recorded on the
// receiver rather than lost in the app UI.

/// Non-identifying device context for a run (no user-assigned device name, to
/// respect the public-repo / no-PII rule).
struct ProbeRunDevice: Codable, Equatable {
    var model: String?
    var systemName: String?
    var systemVersion: String?
}

/// The outcome for one plugin in a probe run.
struct ProbeRunResult: Codable, Equatable {
    var id: String
    var name: String
    var component: ProbeComponent
    var status: String   // "sent" | "probed" | "empty" | "failed"
    var error: String?
    var params: Int
    var writable: Int
    var sanitized: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, component, status, error, params, writable, sanitized
    }
}

/// The full diagnostic record of one probe run.
struct ProbeReport: Codable, Equatable {
    var app: String?
    var startedAt: String?
    var device: ProbeRunDevice?
    var results: [ProbeRunResult]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// The receiver's JSON reply to a successful POST /auv3-probe/diagnostics.
struct DiagnosticsResult: Decodable {
    let total: Int
    let sent: Int
    let empty: Int
    let failed: Int
    let stored: String
}
