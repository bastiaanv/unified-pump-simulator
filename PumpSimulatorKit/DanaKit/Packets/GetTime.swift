import Foundation

extension DanaKitMessages {
    static func processGetTime(_ model: DanaKitProcessMessage) {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date.now)
        guard let year = components.year, let month = components.month, let day = components.day, let hour = components.hour, let minute = components.minute, let second = components.second else {
            logger.error("Failed to procss get Time, missing datecomponent...")
            return
        }

        let content = Data([
            UInt8(year - 2000),
            UInt8(month),
            UInt8(day),
            UInt8(hour),
            UInt8(minute),
            UInt8(second),
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
