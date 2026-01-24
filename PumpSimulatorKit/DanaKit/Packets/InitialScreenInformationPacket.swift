import Foundation

extension DanaKitMessages {
    static func processInitialScreenInformation(_ model: DanaKitProcessMessage) {
        let insulinOnBoard: UInt16 = 0x0000
        let extendedBolusAbsoluteRemaining: UInt16 = 0x0000
        let dailyTotalUnits: UInt16 = 0x0000
        let maxDailyTotalUnits: UInt16 = 0x00FA
        let battery = model.state.batteryPercentage
        let reservoir = UInt16(model.state.reservoirLevel * 100)
        let basalRate = UInt16((model.state.currentBasalRate ?? 0) * 100)
        let tempBasalPercent = model.state.tempBasalPercentage ?? 0

        var status: UInt8 = 0x00
        if model.state.suspendedSince != nil {
            status += 0x01
        }

        if model.state.tempBasalPercentage != nil {
            status += 0x10
        }

        var content: [UInt8] = [
            status,
            UInt8(dailyTotalUnits & 0xFF), // Not used
            UInt8((dailyTotalUnits >> 8) & 0xFF), // Not used
            UInt8(maxDailyTotalUnits & 0xFF), // Not used
            UInt8((maxDailyTotalUnits >> 8) & 0xFF), // Not used
            UInt8(reservoir & 0xFF),
            UInt8((reservoir >> 8) & 0xFF),
            UInt8(basalRate & 0xFF),
            UInt8((basalRate >> 8) & 0xFF),
            UInt8(tempBasalPercent & 0xFF), // Not used
            battery,
            UInt8(extendedBolusAbsoluteRemaining & 0xFF), // Not used
            UInt8((extendedBolusAbsoluteRemaining >> 8) & 0xFF), // Not used
            UInt8(insulinOnBoard & 0xFF), // Not used
            UInt8((insulinOnBoard >> 8) & 0xFF), // Not used
        ]

        if model.state.pumpModel == .DanaI {
            // error state - Not used
            content.append(0x00)
        }

        let message = DanaKitEncryption.encrypt(
            data: Data(content),
            type: DanaKitMessageType.TYPE_RESPONSE,
            opCode: DanaKitMessageType.OPCODE_REVIEW__INITIAL_SCREEN_INFORMATION,
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)
        logger.info("Processed Initial screen message!")
    }
}
