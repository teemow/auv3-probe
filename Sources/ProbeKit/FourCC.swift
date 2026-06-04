import Foundation
import CoreAudioTypes

// FourCharCode (OSType) <-> String helpers, shared by the audio-unit scanner
// (container app) and the AUv3 extensions (which register an AudioComponent and
// log/inspect their own type/subtype/manufacturer codes).

extension FourCharCode {
    /// Render a FourCharCode (`OSType`) as its 4-character string (e.g. "aumu").
    /// Non-printable bytes become "?" so the output stays human-readable.
    public static func string(from code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        let chars = bytes.map { byte -> Character in
            (byte >= 0x20 && byte < 0x7F) ? Character(UnicodeScalar(byte)) : "?"
        }
        return String(chars)
    }

    /// Parse a 4-character string into a FourCharCode (`OSType`). Pads/truncates
    /// to exactly 4 bytes; non-ASCII bytes are coerced to spaces. The inverse of
    /// `string(from:)` for the common ASCII case.
    public static func from(string s: String) -> FourCharCode {
        var bytes = Array(s.utf8.prefix(4))
        while bytes.count < 4 { bytes.append(0x20) } // pad with space
        return (FourCharCode(bytes[0]) << 24)
            | (FourCharCode(bytes[1]) << 16)
            | (FourCharCode(bytes[2]) << 8)
            | FourCharCode(bytes[3])
    }
}
