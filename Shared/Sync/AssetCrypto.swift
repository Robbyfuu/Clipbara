import CryptoKit
import Foundation

/// AES-GCM sealing of large clip payloads under a per-clip 256-bit key.
enum AssetCrypto {
    static func makeKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// Returns nonce + ciphertext + tag (AES.GCM combined representation).
    static func seal(_ plaintext: Data, key: Data) throws -> Data {
        try AES.GCM.seal(plaintext, using: try symmetricKey(key)).combined!
    }

    static func open(_ sealed: Data, key: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: try symmetricKey(key))
    }

    private static func symmetricKey(_ data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw CryptoKitError.incorrectKeySize }
        return SymmetricKey(data: data)
    }
}
