import Foundation

// ProbeDump mirrors the Go device.ProbeDump / ProbeParam / ProbeComponent
// structs in the main mcp-midi-controller repo (internal/device/auv3probe.go).
// The JSON keys are the *only* contract between the two repos, so they are
// pinned here with explicit CodingKeys (camelCase) even though Swift's default
// keying would already match the property names. If the Go structs change,
// this mirror must change with them.

/// The AudioComponentDescription the dump came from. type/subtype/manufacturer
/// are FourCharCode (`OSType`) values rendered as 4-character strings (e.g.
/// "aumu", "aufx").
struct ProbeComponent: Codable, Equatable {
    var type: String
    var subtype: String
    var manufacturer: String
}

/// One `AUParameter` as read from `auAudioUnit.parameterTree`.
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

    enum CodingKeys: String, CodingKey {
        case address
        case keyPath
        case identifier
        case displayName
        case min
        case max
        case value
        case unit
        case unitName
        case valueStrings
        case writable
        case readable
    }
}

/// The full parameter-tree dump for one plugin.
struct ProbeDump: Codable, Equatable {
    var component: ProbeComponent
    var name: String
    var parameters: [ProbeParam]

    enum CodingKeys: String, CodingKey {
        case component
        case name
        case parameters
    }

    /// Encodes the dump to stable, pretty JSON. `.sortedKeys` guarantees a
    /// deterministic ordering so the output diffs cleanly; the receiver
    /// re-encodes anyway, but stable output also helps the Save-to-Files path.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
