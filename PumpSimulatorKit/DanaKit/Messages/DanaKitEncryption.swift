import Foundation

enum DanaKitEncryption {
    static let logger = PumpManagerLogger(subsystem: "com.bastiaanv.danaKit", category: "DanaKitEncryption")

    static var randomSyncKey: UInt8 = 0
    static var pairingKeys = Data([0x79, 0x6F, 0x49, 0xCF, 0xE1, 0x8B])
    static var randomPairingKeys = Data([0x37, 0x95, 0xD7, 0x8F])

    static func xorPacketSerialNumber(data: Data, deviceName: String) -> Data {
        let tmp = Data([
            UInt8(deviceName.utf8CString[0]) &+ UInt8(deviceName.utf8CString[1]) &+ UInt8(deviceName.utf8CString[2]),
            UInt8(deviceName.utf8CString[3]) &+ UInt8(deviceName.utf8CString[4]) &+ UInt8(deviceName.utf8CString[5]) &+
                UInt8(deviceName.utf8CString[6]) &+ UInt8(deviceName.utf8CString[7]),
            UInt8(deviceName.utf8CString[8]) &+ UInt8(deviceName.utf8CString[9]),
        ])

        var buffer = data
        for i in 0 ..< (data.count - 5) {
            buffer[i + 3] ^= tmp[i % 3]
        }

        return buffer
    }

    static func encodePacket(
        data: Data,
        type: UInt8,
        opCode: UInt8,
        pump: DanaPump,
        isEncryptionCommand: Bool,
        deviceName: String
    ) -> Data {
        var payload = Data([type, opCode])
        payload.append(data)

        let crc = generateCrc(buffer: payload, enhancedEncryption: pump, isEncryptionCommand: isEncryptionCommand)

        var fullData = Data([
            0xA5,
            0xA5,
            UInt8(data.count + 2),
        ])
        fullData.append(payload)
        fullData.append(Data([
            UInt8((crc >> 8) & 0xFF),
            UInt8(crc & 0xFF),
            0x5A,
            0x5A,
        ]))

        logger.debug("Encoding value: \(fullData.hexString())")
        return xorPacketSerialNumber(data: fullData, deviceName: deviceName)
    }

    static func encrypt(
        data: Data,
        type: UInt8,
        opCode: UInt8,
        state: DanaKitState,
        isEncryptionCommand: Bool,
        deviceName: String
    ) -> Data {
        var output = encodePacket(
            data: data,
            type: type,
            opCode: opCode,
            pump: state.pumpModel,
            isEncryptionCommand: isEncryptionCommand,
            deviceName: deviceName
        )

        if state.pumpModel == .DanaI {
            if output[0] == 0xA5, output[1] == 0xA5 {
                output[0] = 0xAA
                output[1] = 0xAA
            }

            if output[output.count - 2] == 0x5A, output[output.count - 1] == 0x5A {
                output[output.count - 2] = 0xEE
                output[output.count - 1] = 0xEE
            }

            let bleKeys = state.pumpModel.getEncryptionKey()
            for i in 0 ..< output.count {
                output[i] &+= bleKeys[0]
                output[i] = ((output[i] >> 4) & 0x0F) | (((output[i] & 0x0F) << 4) & 0xF0)

                output[i] &-= bleKeys[1]
                output[i] ^= bleKeys[2]
            }
        } else if state.pumpModel == .DanaRSv3 {
            if output[0] == 0xA5, output[1] == 0xA5 {
                output[0] = 0x7A
                output[1] = 0x7A
            }

            if output[output.count - 2] == 0x5A, output[output.count - 1] == 0x5A {
                output[output.count - 2] = 0x2E
                output[output.count - 1] = 0x2E
            }

            var updatedRandomSyncKey = randomSyncKey
            for i in 0 ..< output.count {
                output[i] ^= pairingKeys[0]
                output[i] &-= updatedRandomSyncKey
                output[i] = ((output[i] >> 4) & 0xF) | ((output[i] & 0xF) << 4)

                output[i] &+= pairingKeys[1]
                output[i] ^= pairingKeys[2]
                output[i] = ((output[i] >> 4) & 0xF) | ((output[i] & 0xF) << 4)

                output[i] &-= pairingKeys[3]
                output[i] ^= pairingKeys[4]
                output[i] = ((output[i] >> 4) & 0x0F) | ((output[i] & 0x0F) << 4)

                output[i] ^= pairingKeys[5]
                output[i] ^= updatedRandomSyncKey

                output[i] ^= secondLvlEncryptionLookup[Int(pairingKeys[0])]
                output[i] &+= secondLvlEncryptionLookup[Int(pairingKeys[1])]
                output[i] &-= secondLvlEncryptionLookup[Int(pairingKeys[2])]
                output[i] = ((output[i] >> 4) & 0x0F) | ((output[i] & 0x0F) << 4)

                output[i] ^= secondLvlEncryptionLookup[Int(pairingKeys[3])]
                output[i] &+= secondLvlEncryptionLookup[Int(pairingKeys[4])]
                output[i] &-= secondLvlEncryptionLookup[Int(pairingKeys[5])]
                output[i] = ((output[i] >> 4) & 0x0F) | ((output[i] & 0x0F) << 4)

                output[i] ^= secondLvlEncryptionLookup[Int(randomPairingKeys[0])]
                output[i] &+= secondLvlEncryptionLookup[Int(randomPairingKeys[1])]
                output[i] &-= secondLvlEncryptionLookup[Int(randomPairingKeys[2])]

                updatedRandomSyncKey = output[i]
            }

            randomSyncKey = updatedRandomSyncKey
        } else {
            logger.error("[encrypt] Unsupported pump model...")
        }

        return output
    }

    static func decrypt(data: Data, state: DanaKitState) -> Data {
        var output = data
        if state.pumpModel == .DanaI {
            let bleKeys = state.pumpModel.getEncryptionKey()
            for i in 0 ..< output.count {
                output[i] ^= bleKeys[2]
                output[i] &+= bleKeys[1]

                output[i] = ((output[i] >> 4) & 0xF) | (((output[i] & 0xF) << 4) & 0xFF)
                output[i] &-= bleKeys[0]
            }
        } else if state.pumpModel == .DanaRSv3 {
            for i in 0 ..< output.count {
                let copyRandomSyncKey = output[i]

                output[i] &+= secondLvlEncryptionLookup[Int(randomPairingKeys[2])]
                output[i] &-= secondLvlEncryptionLookup[Int(randomPairingKeys[1])]
                output[i] ^= secondLvlEncryptionLookup[Int(randomPairingKeys[0])]
                output[i] = ((output[i] >> 4) & 0xF) | (((output[i] & 0xF) << 4) & 0xFF)

                output[i] &+= secondLvlEncryptionLookup[Int(pairingKeys[5])]
                output[i] &-= secondLvlEncryptionLookup[Int(pairingKeys[4])]
                output[i] ^= secondLvlEncryptionLookup[Int(pairingKeys[3])]
                output[i] = ((output[i] >> 4) & 0xF) | (((output[i] & 0xF) << 4) & 0xFF)

                output[i] &+= secondLvlEncryptionLookup[Int(pairingKeys[2])]
                output[i] &-= secondLvlEncryptionLookup[Int(pairingKeys[1])]
                output[i] ^= secondLvlEncryptionLookup[Int(pairingKeys[0])]
                output[i] ^= randomSyncKey
                output[i] ^= pairingKeys[5]

                output[i] = ((output[i] >> 4) & 0xF) | (((output[i] & 0xF) << 4) & 0xFF)
                output[i] ^= pairingKeys[4]
                output[i] &+= pairingKeys[3]

                output[i] = ((output[i] >> 4) & 0xF) | (((output[i] & 0xF) << 4) & 0xFF)
                output[i] ^= pairingKeys[2]
                output[i] &-= pairingKeys[1]

                output[i] = ((output[i] >> 4) & 0xF) | (((output[i] & 0xF) << 4) & 0xFF)
                output[i] &+= randomSyncKey
                output[i] ^= pairingKeys[0]

                randomSyncKey = copyRandomSyncKey
            }

            if output[0] == 0x7A, output[1] == 0x7A {
                output[0] = 0xA5
                output[1] = 0xA5
            }

            if output[output.count - 2] == 0x2E, output[output.count - 1] == 0x2E {
                output[output.count - 2] = 0x5A
                output[output.count - 1] = 0x5A
            }
        } else {
            logger.error("[decrypt] Unsupported pump model...")
        }

        return output
    }

    static func generateCrc(buffer: Data, enhancedEncryption: DanaPump, isEncryptionCommand: Bool) -> UInt16 {
        var crc: UInt16 = 0

        for byte in buffer {
            var result = ((crc >> 8) | (crc << 8)) ^ UInt16(byte)
            result ^= (result & 0xFF) >> 4
            result ^= (result << 12)

            if enhancedEncryption == .DanaRSv3 {
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
