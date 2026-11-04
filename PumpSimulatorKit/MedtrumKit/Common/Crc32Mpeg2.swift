import Foundation

/// CRC-32/MPEG-2 (polynomial 0x04C11DB7, initial value 0xFFFFFFFF, no reflection, no final XOR): what a patch record
/// ends with, computed over the record from its 0xAA header byte and stored little-endian. Checked against records of
/// real patches.
enum Crc32Mpeg2 {
    private static let table: [UInt32] = (0 ..< 256).map { index in
        var crc = UInt32(index) << 24
        for _ in 0 ..< 8 {
            crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
        }
        return crc
    }

    static func calculate(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)]
        }
        return crc
    }
}
