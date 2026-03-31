import Foundation

extension UInt64 {
    func toData(length: Int) -> Data {
        var output = Data(count: length)
        for i in 0 ..< length {
            output[i] = UInt8((self >> (i * 8)) & 0xFF)
        }

        return output
    }
}

extension UInt32 {
    func toData() -> Data {
        var output = Data(count: 4)
        for i in 0 ..< 4 {
            output[i] = UInt8((self >> (i * 8)) & 0xFF)
        }

        return output
    }
}

extension UInt16 {
    func toData() -> Data {
        var output = Data(count: 2)
        for i in 0 ..< 2 {
            output[i] = UInt8((self >> (i * 8)) & 0xFF)
        }

        return output
    }
}
