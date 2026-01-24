import Foundation

extension DanaKitMessages {
    static func processHistoryMode(_ model: DanaKitProcessMessage) {
        logger.info("Toggle history upload to \(model.data[2] == 0x01 ? "ON" : "OFF")")
        model.state.historyUploadMode = model.data[2] == 0x01

        let message = DanaKitEncryption.encrypt(
            data: Data([0x00]),
            type: DanaKitMessageType.TYPE_RESPONSE,
            opCode: DanaKitMessageType.OPCODE_REVIEW__SET_HISTORY_UPLOAD_MODE,
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)
        logger.info("Processed history upload mode message!")
    }

    static func processHistory(_ model: DanaKitProcessMessage) {
        // TODO: Actually upload history item

        // Upload complete!
        let message = DanaKitEncryption.encrypt(
            data: Data([0x00, 0x00, 0x00]),
            type: DanaKitMessageType.TYPE_RESPONSE,
            opCode: model.data[1],
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)
        logger.info("Processed history upload message!")
    }
}
