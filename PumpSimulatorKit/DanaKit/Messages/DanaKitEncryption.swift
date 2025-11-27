import Foundation

enum DanaKitEncryption {
    static func decodePacketSerialNumber(data: Data, deviceName: String) -> Data {
        let tmp = Data([
            UInt8(deviceName.utf8CString[0]) &+ UInt8(deviceName.utf8CString[1]) &+ UInt8(deviceName.utf8CString[2]),
            UInt8(deviceName.utf8CString[3]) &+ UInt8(deviceName.utf8CString[4]) &+ UInt8(deviceName.utf8CString[5]) &+
                UInt8(deviceName.utf8CString[6]) &+ UInt8(deviceName.utf8CString[7]),
            UInt8(deviceName.utf8CString[8]) &+ UInt8(deviceName.utf8CString[9])
        ])

        var buffer = data
        for i in 0 ..< (data.count - 5) {
            buffer[i + 3] ^= tmp[i % 3]
        }

        return buffer
    }
    
    static func generateCrc(buffer: Data, enhancedEncryption: DanaPump, isEncryptionCommand: Bool) -> UInt16 {
        var crc: UInt16 = 0

        for byte in buffer {
            var result = ((crc >> 8) | (crc << 8)) ^ UInt16(byte)
            result ^= (result & 0xFF) >> 4
            result ^= (result << 12)

            if enhancedEncryption == .DanaRSv1 {
                let tmp = (result & 0xFF) << 3 | ((result & 0xFF) >> 2) << 5
                result ^= tmp
            } else if enhancedEncryption == .DanaRSv3 {
                var tmp: UInt16 = 0
                if isEncryptionCommand {
                    tmp = (result & 0xFF) << 3 | ((result & 0xFF) >> 2) << 5
                } else {
                    tmp = (result & 0xFF) << 5 | ((result & 0xFF) >> 4) << 2
                }
                result ^= tmp
            } else if enhancedEncryption == .DanaI {
                var tmp: UInt16 = 0
                if isEncryptionCommand {
                    tmp = (result & 0xFF) << 3 | ((result & 0xFF) >> 2) << 5
                } else {
                    tmp = (result & 0xFF) << 4 | ((result & 0xFF) >> 3) << 2
                }
                result ^= tmp
            }

            crc = result
        }

        return crc
    }
}
