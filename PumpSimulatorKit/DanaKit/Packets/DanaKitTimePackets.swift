import Foundation

extension DanaKitMessages {
    static func processGetTime(_ model: DanaKitProcessMessage) {
        guard model.state.pumpModel != .DanaI else {
            logger.error("[GetTime] This message is NOT availble on the Dana-I")
            return
        }

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date.now)

        guard let year = components.year, let month = components.month, let day = components.day, let hour = components.hour,
              let minute = components.minute, let second = components.second
        else {
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
            opCode: DanaKitMessageType.OPCODE_OPTION__GET_PUMP_TIME,
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)
        logger.info("Processed Get time message!")
    }

    static func processGetTimeWithUtc(_ model: DanaKitProcessMessage) {
        guard model.state.pumpModel == .DanaI else {
            logger.error("[GetTimeWithUtc] This message is only availble on the Dana-I")
            return
        }

        guard let utcTimezone = TimeZone(identifier: "GMT") else {
            logger.error("[GetTimeWithUtc] UTC timezone is not available on this machine...")
            return
        }

        var calendar = Calendar.current
        calendar.timeZone = utcTimezone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date.now)

        guard let year = components.year, let month = components.month, let day = components.day, let hour = components.hour,
              let minute = components.minute, let second = components.second
        else {
            logger.error("[GetTimeWithUtc] Failed to procss get Time, missing datecomponent...")
            return
        }

        let content = Data([
            UInt8(year - 2000),
            UInt8(month),
            UInt8(day),
            UInt8(hour),
            UInt8(minute),
            UInt8(second),
            UInt8(bitPattern: Int8(TimeZone.current.secondsFromGMT() / 3600)),
        ])

        let message = DanaKitEncryption.encrypt(
            data: Data(content),
            type: DanaKitMessageType.TYPE_RESPONSE,
            opCode: DanaKitMessageType.OPCODE_OPTION__GET_PUMP_UTC_AND_TIME_ZONE,
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)
        logger.info("Processed Get time message with UTC!")
    }

    static func processSetTime(_ model: DanaKitProcessMessage) {
        logger.info("[setTime] Ignoring set time request...")

        let message = DanaKitEncryption.encrypt(
            data: Data([0x00]),
            type: DanaKitMessageType.TYPE_RESPONSE,
            opCode: DanaKitMessageType.OPCODE_OPTION__SET_PUMP_TIME,
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)
        logger.info("Processed Set time message!")
    }

    static func processSetTimeWithUtc(_ model: DanaKitProcessMessage) {
        logger.info("[setTimeWithUtc] Ignoring set time request...")

        let message = DanaKitEncryption.encrypt(
            data: Data([0x00]),
            type: DanaKitMessageType.TYPE_RESPONSE,
            opCode: DanaKitMessageType.OPCODE_OPTION__SET_PUMP_UTC_AND_TIME_ZONE,
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)
        logger.info("Processed Set time with utc message!")
    }
}
