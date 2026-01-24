import Foundation

extension DanaKitAuthMessages {
    static func processPumpCheck(_ model: DanaKitProcessAuthMessage) {
        guard let receivedDeviceName = String(data: model.data.subdata(in: 5 ..< 15), encoding: .ascii) else {
            logger.error("Could not decode device name from data")
            return
        }

        guard receivedDeviceName == model.deviceName else {
            logger.error("Received invalid device name - expected \(model.deviceName), actual: \(receivedDeviceName)")
            return
        }

        var data = Data([0x4F, 0x4B]) // O, K
        if model.pump == .DanaRSv3 || model.pump == .DanaI {
            data.append(Data([0, model.pump.getHardwareModel(), 0, model.pump.getProtocol()]))

            // Dana-I will return 6 digit key, while the DanaRSv3 will return a sync key
            data.append(model.pump.getBle5Keys())
        }

        let message = DanaKitEncryption.encodePacket(
            data: data,
            type: DanaKitMessageType.TYPE_ENCRYPTION_RESPONSE,
            opCode: DanaKitMessageType.OPCODE_ENCRYPTION__PUMP_CHECK,
            pump: model.pump,
            isEncryptionCommand: true,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)

        logger.info("Processed Pump Check message!")
    }
}
