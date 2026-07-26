import CryptoKit
import Foundation

/// The one SHA-256 used everywhere content identity matters (shared-document revision
/// comparison, compiled-command ownership checks). Backed by CryptoKit rather than a
/// hand-rolled implementation; correctness is still pinned in tests against NIST
/// vectors and the system `shasum -a 256` binary.
enum SHA256Digest {
    static func hexString(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ text: String) -> String {
        hexString(Data(text.utf8))
    }

    static func hex(_ data: Data) -> String {
        hexString(data)
    }
}
