import Foundation

/// HKDF-SHA256 used for the JPAKE key-confirmation digest and to derive the
/// message signing key. Port of TandemKit's `Hkdf.swift`.
enum TandemMobiHkdf {
    static func build(nonce: Data, keyMaterial: Data) -> Data {
        // HKDF-Extract
        let prk = TandemMobiHmac.hmacSha256(data: keyMaterial, key: nonce)

        // HKDF-Expand (info empty, 32 output bytes)
        var okm = Data()
        var previous = Data()
        var counter: UInt8 = 1
        while okm.count < 32 {
            let input = TandemMobiBytes.combine(previous, Data([counter]))
            previous = TandemMobiHmac.hmacSha256(data: input, key: prk)
            okm.append(previous)
            counter &+= 1
        }
        return okm.prefix(32)
    }
}
