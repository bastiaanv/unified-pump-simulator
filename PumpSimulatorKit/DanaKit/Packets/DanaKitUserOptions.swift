import Foundation

extension DanaKitMessages {
    static func processGetUserOptions(_ model: DanaKitProcessMessage) {
        var content = Data([
            model.state.timeDisplayIn12H ? 1 : 0,
            model.state.buttonScroll ? 1 : 0,
            model.state.alarmType.rawValue,
            model.state.lcdOnInSeconds,
            model.state.backlightOnInSeconds,
            model.state.selectedLanguage,
            model.state.bgUnit.rawValue,
            model.state.shutdownInHours,
            model.state.lowReservoirWarning,
            UInt8(model.state.cannulaVolume & 0xFF),
            UInt8(model.state.cannulaVolume >> 8),
            UInt8(model.state.refillAmount & 0xFF),
            UInt8(model.state.refillAmount >> 8),
            1, // Selectable language 1
            1, // Selectable language 2
            1, // Selectable language 3
            1, // Selectable language 4
            1, // Selectable language 5
        ])

        if model.state.pumpModel == .DanaI {
            content.append(Data([
                UInt8(model.state.targetBg),
                UInt8(model.state.targetBg >> 8),
            ]))
        }

        let message = DanaKitEncryption.encrypt(
            data: Data(content),
            type: DanaKitMessageType.TYPE_RESPONSE,
            opCode: DanaKitMessageType.OPCODE_OPTION__GET_USER_OPTION,
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)
        logger.info("Processed Get user options message!")
    }

    static func processSetUserOptions(_ model: DanaKitProcessMessage) {
        model.state.timeDisplayIn12H = model.data[2] == 0x01
        model.state.buttonScroll = model.data[3] == 0x01
        model.state.alarmType = AlarmType(rawValue: model.data[4]) ?? .Both
        model.state.lcdOnInSeconds = model.data[5]
        model.state.backlightOnInSeconds = model.data[6]
        model.state.selectedLanguage = model.data[7]
        model.state.bgUnit = BgUnit(rawValue: model.data[8]) ?? .MgDl
        model.state.shutdownInHours = model.data[9]
        model.state.lowReservoirWarning = model.data[10]
        model.state.cannulaVolume = UInt16(model.data[11]) | UInt16(model.data[12]) << 8
        model.state.refillAmount = UInt16(model.data[13]) | UInt16(model.data[14]) << 8

        if model.state.pumpModel == .DanaI {
            model.state.targetBg = UInt16(model.data[15]) | UInt16(model.data[16]) << 8
        }

        let message = DanaKitEncryption.encrypt(
            data: Data([0x00]),
            type: DanaKitMessageType.TYPE_RESPONSE,
            opCode: DanaKitMessageType.OPCODE_OPTION__SET_USER_OPTION,
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)
        logger.info("Processed Set user options message!")
    }
}
