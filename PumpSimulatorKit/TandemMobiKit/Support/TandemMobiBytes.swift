import Foundation
import Security

/// Cryptographically secure random bytes (SecRandomCopyBytes with a fallback).
enum TandemMobiRandom {
    static func bytes(_ count: Int) -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { ptr -> Int32 in
            SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        if result == errSecSuccess {
            return data
        }
        return Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max) })
    }
}

/// Namespaced byte helpers for the Tandem Mobi sim. Modeled on
/// TandemKit/Sources/TandemCore/Common/Bytes.swift (little-endian throughout).
enum TandemMobiBytes {
    static func combine(_ parts: Data...) -> Data {
        var result = Data()
        for part in parts {
            result.append(part)
        }
        return result
    }

    static func firstN(_ data: Data, _ n: Int) -> Data {
        data.prefix(n)
    }

    static func dropFirstN(_ data: Data, _ n: Int) -> Data {
        guard n <= data.count else { return Data() }
        return data.subdata(in: n ..< data.count)
    }

    // MARK: - Little-endian writers

    static func u8(_ value: UInt8) -> Data {
        Data([value])
    }

    static func u16(_ value: UInt16) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }

    static func u32(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }

    static func u64(_ value: UInt64) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }

    // MARK: - Little-endian readers

    static func readU8(_ data: Data, _ offset: Int) -> UInt8 {
        data[offset]
    }

    static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    static func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0 ..< 8 {
            value |= UInt64(data[offset + i]) << (8 * i)
        }
        return value
    }

    /// Zero-pads `data` to `length` (or truncates if longer).
    static func pad(_ data: Data, to length: Int) -> Data {
        if data.count == length {
            return data
        }
        if data.count > length {
            return data.prefix(length)
        }
        var padded = Data(data)
        padded.append(Data(repeating: 0, count: length - data.count))
        return padded
    }
}
