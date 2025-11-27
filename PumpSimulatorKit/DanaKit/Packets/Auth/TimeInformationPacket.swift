import Foundation

extension DanaKitAuthMessages {
    static func processTimeInformation(_ model: DanaKitProcessAuthMessage) {
        if model.pump == .DanaI {
            // Just confirm time information message
            let message = DanaKitEncryption.encodePacket(
                data: Data([]),
                type: DanaKitMessageType.TYPE_ENCRYPTION_RESPONSE,
                opCode: DanaKitMessageType.OPCODE_ENCRYPTION__TIME_INFORMATION,
                pump: model.pump,
                isEncryptionCommand: true,
                deviceName: model.deviceName
            )
            DanaKitWriter.write(message, model.writeParams)
            
        } else if model.pump == .DanaRSv3 {
            logger.error("TODO: Implement time information message for DanaRSv3")
            
        } else {
            logger.error("Time information response for DanaRSv1 is not implemented...")
        }
        
        logger.info("Processed Time Information message!")
    }
}
