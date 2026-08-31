import Foundation

/// Little-endian byte helpers used throughout the MiniMed packet code.
/// Multi-byte integers on the wire are LITTLE-ENDIAN (`packets/00_README.md`).
extension Data {
    /// Read a little-endian `UInt8` at `offset`.
    func miniMedUInt8(_ offset: Int) -> UInt8 {
        guard offset < count else { return 0 }
        return self[offset]
    }

    /// Read a little-endian `UInt16` at `offset`.
    func miniMedUInt16(_ offset: Int) -> UInt16 {
        guard offset + 1 < count else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    /// Read a little-endian `UInt32` at `offset`.
    func miniMedUInt32(_ offset: Int) -> UInt32 {
        guard offset + 3 < count else { return 0 }
        var value: UInt32 = 0
        for i in 0 ..< 4 {
            value |= UInt32(self[offset + i]) << (8 * i)
        }
        return value
    }

    /// Read a little-endian `Int32` at `offset`.
    func miniMedInt32(_ offset: Int) -> Int32 {
        Int32(bitPattern: miniMedUInt32(offset))
    }

    /// Read a little-endian `Int8` (signed) at `offset`.
    func miniMedInt8(_ offset: Int) -> Int8 {
        guard offset < count else { return 0 }
        return Int8(bitPattern: self[offset])
    }

    /// Read an ASCII string of `length` bytes starting at `offset` (trimmed at NUL).
    func miniMedString(_ offset: Int, length: Int) -> String {
        guard offset + length <= count else { return "" }
        let bytes = subdata(in: offset ..< (offset + length))
        let trimmed = bytes.split(separator: 0x00, omittingEmptySubsequences: false).first ?? bytes
        return String(data: trimmed, encoding: .utf8) ?? ""
    }
}

extension UInt16 {
    /// LE bytes.
    func miniMedData() -> Data {
        var out = Data(count: 2)
        out[0] = UInt8(self & 0xFF)
        out[1] = UInt8((self >> 8) & 0xFF)
        return out
    }
}

extension UInt32 {
    /// LE bytes.
    func miniMedData() -> Data {
        var out = Data(count: 4)
        for i in 0 ..< 4 {
            out[i] = UInt8((self >> (8 * i)) & 0xFF)
        }
        return out
    }
}

extension Int32 {
    /// LE bytes.
    func miniMedData() -> Data {
        UInt32(bitPattern: self).miniMedData()
    }
}

extension Int {
    var miniMedUInt32: UInt32 {
        UInt32(self)
    }
}
