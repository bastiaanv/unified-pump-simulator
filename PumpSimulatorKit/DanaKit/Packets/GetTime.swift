import Foundation

extension DanaKitMessages {
    static func processGetTime(_ model: DanaKitProcessMessage) {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date.now)
        let content = Data([
            
        ])
        
        let message = DanaKitEncryption.encrypt(
            data: Data(content),
            type: DanaKitMessageType.TYPE_RESPONSE,
            opCode: DanaKitMessageType.OPCODE_REVIEW__INITIAL_SCREEN_INFORMATION,
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)
        logger.info("Processed Get time message!")
    }
}
