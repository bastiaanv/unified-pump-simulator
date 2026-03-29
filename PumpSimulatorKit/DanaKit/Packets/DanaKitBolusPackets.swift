import Foundation

extension DanaKitMessages {
    static var bolusTimer: Timer?

    static func processStartBolus(_ model: DanaKitProcessMessage) {
        var status: UInt8 = 0x00

        if model.state.suspendedSince != nil {
            logger.warning("[startBolus] Pump is suspended. Ignoring start bolus...")
            status = 0x01
        } else {
            logger.info("Starting bolus!")

            let amount = UInt16(model.data[2]) | UInt16(model.data[3]) << 8
            let speed = BolusSpeed(rawValue: model.data[4]) ?? .speed12

            scheduleBolusTime(amount: amount, speed: speed, model)
        }

        let message = DanaKitEncryption.encrypt(
            data: Data([status]),
            type: DanaKitMessageType.TYPE_RESPONSE,
            opCode: DanaKitMessageType.OPCODE_BOLUS__SET_STEP_BOLUS_START,
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)
        logger.info("Processed Bolus start message!")
    }

    static func processStopBolus(_ model: DanaKitProcessMessage) {
        var status: UInt8 = 0x00

        if let bolusTimer = bolusTimer {
            bolusTimer.invalidate()
            self.bolusTimer = nil
        } else {
            status = 0x01
        }

        let message = DanaKitEncryption.encrypt(
            data: Data([status]),
            type: DanaKitMessageType.TYPE_RESPONSE,
            opCode: DanaKitMessageType.OPCODE_BOLUS__SET_STEP_BOLUS_STOP,
            state: model.state,
            isEncryptionCommand: false,
            deviceName: model.deviceName
        )
        DanaKitWriter.write(message, model.writeParams)
        logger.info("Processed Bolus start message!")
    }

    private static func scheduleBolusTime(amount: UInt16, speed: BolusSpeed, _ model: DanaKitProcessMessage) {
        let originalReservoirLevel = model.state.reservoirLevel
        let startTime = Date.now
        let endTime = startTime.addingTimeInterval(speed.getDuration(amount: amount))

        DispatchQueue.main.async {
            bolusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                let progress = Date.now.timeIntervalSince(startTime) / endTime.timeIntervalSince(startTime)

                if progress >= 1 {
                    model.state.reservoirLevel = originalReservoirLevel - (Double(amount) / 100)
                    model.pumpManager.notifyStateUpdate()

                    let message = DanaKitEncryption.encrypt(
                        data: Data([
                            UInt8(amount & 0xFF),
                            UInt8(amount >> 8),
                        ]),
                        type: DanaKitMessageType.TYPE_NOTIFY,
                        opCode: DanaKitMessageType.OPCODE_NOTIFY__DELIVERY_COMPLETE,
                        state: model.state,
                        isEncryptionCommand: false,
                        deviceName: model.deviceName
                    )
                    DanaKitWriter.write(message, model.writeParams)
                    logger.info("Bolus completed!")

                    bolusTimer?.invalidate()
                    bolusTimer = nil
                } else {
                    let currentAmount = UInt16(progress * Double(amount))
                    model.state.reservoirLevel = originalReservoirLevel - (Double(currentAmount) / 100)
                    model.pumpManager.notifyStateUpdate()

                    let message = DanaKitEncryption.encrypt(
                        data: Data([
                            UInt8(currentAmount & 0xFF),
                            UInt8(currentAmount >> 8),
                        ]),
                        type: DanaKitMessageType.TYPE_NOTIFY,
                        opCode: DanaKitMessageType.OPCODE_NOTIFY__DELIVERY_RATE_DISPLAY,
                        state: model.state,
                        isEncryptionCommand: false,
                        deviceName: model.deviceName
                    )
                    DanaKitWriter.write(message, model.writeParams)
                    logger.info("Bolus notify - amount: \(currentAmount)")
                }
            }
        }
    }
}
