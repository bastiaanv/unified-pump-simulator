import Foundation

extension DanaKitMessages {
    static func processTempBasalStart(_ model: DanaKitProcessMessage) {
        model.state.tempBasalStart = Date.now
        if model.data[1] == DanaKitMessageType.OPCODE_BASAL__SET_TEMPORARY_BASAL {
            model.state.tempBasalPercentage = min(UInt16(model.data[2]), 500)
            model.state.tempBasalDuration = .hours(Double(model.data[3]))
        } else {
            model.state.tempBasalPercentage = min(UInt16(model.data[2]) | UInt16(model.data[3]) << 8, 500)
            model.state.tempBasalDuration = .minutes(model.data[4] == 160 ? 30 : 15)
        }

        let message = DanaKitEncryption.encrypt(
            data: Data([0x00]),
            type: DanaKitMessageType.TYPE_RESPONSE,
            opCode: model.data[1],
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)
        logger.info("Processed Start temp basal message!")
    }

    static func processTempBasalEnd(_ model: DanaKitProcessMessage) {
        var status: UInt8 = 0x00
        if model.state.tempBasalStart == nil {
            status = 0x01
        } else {
            model.state.tempBasalStart = nil
            model.state.tempBasalPercentage = nil
            model.state.tempBasalDuration = nil
        }

        let message = DanaKitEncryption.encrypt(
            data: Data([status]),
            type: DanaKitMessageType.TYPE_RESPONSE,
            opCode: DanaKitMessageType.OPCODE_BASAL__CANCEL_TEMPORARY_BASAL,
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)
        logger.info("Processed Cancel temp basal message!")
    }

    static func processSuspend(_ model: DanaKitProcessMessage) {
        model.state.suspendedSince = Date.now
        model.state.tempBasalPercentage = nil
        model.state.tempBasalStart = nil
        model.state.tempBasalDuration = nil

        let message = DanaKitEncryption.encrypt(
            data: Data([0x00]),
            type: DanaKitMessageType.TYPE_RESPONSE,
            opCode: DanaKitMessageType.OPCODE_BASAL__SET_SUSPEND_ON,
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)
        logger.info("Processed Cancel temp basal message!")
    }

    static func processResume(_ model: DanaKitProcessMessage) {
        model.state.suspendedSince = nil
        model.state.tempBasalPercentage = nil
        model.state.tempBasalStart = nil
        model.state.tempBasalDuration = nil

        let message = DanaKitEncryption.encrypt(
            data: Data([0x00]),
            type: DanaKitMessageType.TYPE_RESPONSE,
            opCode: DanaKitMessageType.OPCODE_BASAL__SET_SUSPEND_OFF,
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)
        logger.info("Processed Cancel temp basal message!")
    }
}
