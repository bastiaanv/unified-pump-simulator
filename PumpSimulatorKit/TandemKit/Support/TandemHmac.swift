import CryptoKit
import Foundation

/// HMAC-SHA1 / HMAC-SHA256 / SHA256 helpers. The simulator targets macOS where
/// CryptoKit is always available, matching TandemKit's CryptoKit-backed helpers.
enum TandemHmac {
    static func hmacSha1(data: Data, key: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let auth = HMAC<Insecure.SHA1>.authenticationCode(for: data, using: symmetricKey)
        return Data(auth)
    }

    static func hmacSha256(data: Data, key: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let auth = HMAC<CryptoKit.SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(auth)
    }

    static func sha256(_ data: Data) -> Data {
        Data(CryptoKit.SHA256.hash(data: data))
    }
}
