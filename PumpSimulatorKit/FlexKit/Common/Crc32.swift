import Foundation

/// ISO-HDLC / standard CRC-32 used by `WriteControllerData` (`packets/05 §3.1`).
/// The CRC is computed over the full payload (the type byte + per-type fields),
/// i.e. everything after the `[0x15][len]` prefix on the wire.
enum Crc32 {
    private static let polynomial: UInt32 = 0xEDB8_8320

    static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0 ..< 256 {
            var crc = UInt32(i)
            for _ in 0 ..< 8 {
                crc = (crc & 1) != 0 ? (polynomial ^ (crc >> 1)) : (crc >> 1)
            }
            table[i] = crc
        }
        return table
    }()

    /// Standard CRC-32 (init 0xFFFFFFFF, final XOR 0xFFFFFFFF).
    static func calculate(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
