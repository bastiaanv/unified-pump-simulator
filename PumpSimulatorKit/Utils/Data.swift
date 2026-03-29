import Foundation

extension Data {
    init(hex: String) {
        guard hex.count.isMultiple(of: 2) else {
            fatalError("No a multiple of 2")
        }

        let chars = hex.map { $0 }
        let bytes = stride(from: 0, to: chars.count, by: 2)
            .map { String(chars[$0]) + String(chars[$0 + 1]) }
            .compactMap { UInt8($0, radix: 16) }

        guard hex.count / bytes.count == 2 else {
            fatalError("No a multiple of 2")
        }
        self.init(bytes)
    }

    func hexString() -> String {
        let format = "%02hhx"
        return map { String(format: format, $0) }.joined()
    }

    func toUInt16(offset: Int) -> UInt16 {
        UInt16(self[offset + 1]) << 8 | UInt16(self[offset])
    }

    func toUInt64(offset: Int, count: Int) -> UInt64 {
        var result: UInt64 = 0
        for i in 0 ..< count {
            result |= UInt64(self[offset + i]) << (8 * i)
        }

        return result
    }
}
