import Foundation

extension DanaKitMessages {
    static func processKeepAlive(_ model: DanaKitProcessMessage) {
        let message = DanaKitEncryption.encrypt(
            data: Data([0]),
            type: DanaKitMessageType.TYPE_RESPONSE,
            opCode: DanaKitMessageType.OPCODE_ETC__KEEP_CONNECTION,
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)

        logger.info("Processed Keep Alive message!")
    }
}
