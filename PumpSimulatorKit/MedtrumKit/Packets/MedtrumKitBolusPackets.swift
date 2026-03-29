import Foundation

extension MedtrumKitPackets {
    static var bolusTimer: Timer?

    static func startBolus(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        let amount = Double(params.data.toUInt16(offset: 7)) * 0.05

        bluetoothManager.writeResponse(
            data: Data(),
            status: .ok,
            params.responseParam
        )

        scheduleBolus(
            amount: amount,
            pumpManager: params.pumpManager,
            bluetoothManager: bluetoothManager,
            updateParam: params.updateParam
        )

        logger.info("Processed Start bolus message!")
    }

    static func stopBolus(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        guard let bolusTimer = Self.bolusTimer else {
            bluetoothManager.writeResponse(
                data: Data(),
                status: .invalidState,
                params.responseParam
            )
            return
        }

        bolusTimer.invalidate()
        Self.bolusTimer = nil

        bluetoothManager.writeResponse(
            data: Data(),
            status: .ok,
            params.responseParam
        )
        logger.info("Processed Stop bolus message!")
    }

    private static func scheduleBolus(
        amount: Double,
        pumpManager: MedtrumKitPumpManager,
        bluetoothManager: MedtrumKitBluetoothManager,
        updateParam: MedtrumKitBluetoothManager.WriteResponseParam
    ) {
        // 1.5 unit per minute
        let duration = amount / 1.5 * TimeInterval(minutes: 1)
        let startTime = Date.now
        let endTime = startTime.addingTimeInterval(duration)

        pumpManager.state.bolusTotal = amount
        pumpManager.notifyStateDidUpdate()

        DispatchQueue.main.async {
            bolusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                let progressPercentage = Date.now.timeIntervalSince(startTime) / endTime.timeIntervalSince(startTime)
                let progress = amount * progressPercentage
                pumpManager.state.bolusProgress = progress

                bluetoothManager.writeResponse(
                    data: MedtrumKitPackets.generateSynchronizePacket(state: pumpManager.state),
                    status: .ok,
                    updateParam
                )

                if progressPercentage >= 1.0 {
                    bolusTimer?.invalidate()
                    bolusTimer = nil
                }
            }
        }
    }
}
