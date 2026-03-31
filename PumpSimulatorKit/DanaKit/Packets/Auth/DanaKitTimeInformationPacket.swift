import Foundation

extension DanaKitAuthMessages {
    static func processTimeInformation(_ model: DanaKitProcessAuthMessage) {
        var content = Data()
        if model.pump == .DanaI {
        } else if model.pump == .DanaRSv3 {
            content = Data([0x00])

        } else {
            logger.error("Time information response for DanaRSv1 is not implemented...")
            return
        }

        let message = DanaKitEncryption.encodePacket(
            data: Data(content),
            type: DanaKitMessageType.TYPE_ENCRYPTION_RESPONSE,
            opCode: DanaKitMessageType.OPCODE_ENCRYPTION__TIME_INFORMATION,
            pump: model.pump,
            isEncryptionCommand: true,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)

        logger.info("Processed Time Information message!")
    }
}
