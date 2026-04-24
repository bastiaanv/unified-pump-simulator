import Foundation

extension MedtrumKitPackets {
    static var bolusTimer: Timer?
    private static let supportedBolusVolumes = (1 ... 600).map { Double($0) / 20 }

    static func startBolus(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        guard params.pumpManager.state.patchState == .active else {
            logger.warning("Attempted startBolus during non-active state...")
            bluetoothManager.writeResponse(
                data: Data(),
                status: .invalidState,
                params.responseParam
            )
            return
        }

        let amount = Double(params.data.toUInt16(offset: 5)) * 0.05

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

        params.pumpManager.state.bolusTotal = nil
        params.pumpManager.state.bolusProgress = nil
        params.pumpManager.notifyStateDidUpdate()

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
        let originalReservoirLevel = pumpManager.state.reservoirLevel

        pumpManager.state.bolusTotal = amount
        pumpManager.notifyStateDidUpdate()

        DispatchQueue.main.async {
            bolusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                let progressPercentage = Date.now.timeIntervalSince(startTime) / endTime.timeIntervalSince(startTime)
                let progress = roundToSupportedBolusVolume(amount * progressPercentage)

                pumpManager.state.reservoirLevel = originalReservoirLevel - progress
                pumpManager.state.bolusProgress = progress
                pumpManager.notifyStateDidUpdate()

                bluetoothManager.writeResponse(
                    data: MedtrumKitPackets.generateSynchronizePacket(state: pumpManager.state),
                    status: .ok,
                    updateParam
                )

                if progressPercentage >= 1.0 {
                    bolusTimer?.invalidate()
                    bolusTimer = nil

                    pumpManager.state.bolusTotal = nil
                    pumpManager.state.bolusProgress = nil
                    pumpManager.notifyStateDidUpdate()
                }
            }
        }
    }

    private static func roundToSupportedBolusVolume(_ amount: Double) -> Double {
        supportedBolusVolumes.last(where: { $0 <= amount }) ?? 0
    }
}
