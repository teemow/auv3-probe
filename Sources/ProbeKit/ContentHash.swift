import Foundation
import CryptoKit

/// The hash the session sync keeps of a file's bytes, to tell a file that
/// changed from one whose date merely moved.
public enum ContentHash {
    /// SHA-256 of `data`, lowercase hex.
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
