import Foundation

extension MedtrumKitPackets {
    static var primeTimer: Timer?

    static func parsePrimePacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        guard params.pumpManager.state.patchState.rawValue >= PatchState.filled.rawValue else {
            bluetoothManager.writeResponse(
                data: Data(),
                status: .invalidState,
                params.responseParam
            )

            logger.warning("Rejecting prime command - Current state: \(params.pumpManager.state.patchState)")
            return
        }

        params.pumpManager.state.patchState = .priming
        params.pumpManager.state.primeProgress = 1
        params.pumpManager.state.tempBasalStart = nil
        params.pumpManager.state.tempBasalPercentage = nil
        params.pumpManager.state.tempBasalDuration = nil
        params.pumpManager.state.suspendedSince = nil
        params.pumpManager.notifyStateDidUpdate()

        bluetoothManager.writeResponse(
            data: Data(),
            status: .ok,
            params.responseParam
        )

        schedulePrimeUpdate(params, bluetoothManager)
    }

    static func parseActivatePacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        guard params.pumpManager.state.patchState.rawValue < PatchState.active.rawValue else {
            bluetoothManager.writeResponse(
                data: Data(),
                status: .invalidState,
                params.responseParam
            )

            logger.warning("Rejecting activate command - Current state: \(params.pumpManager.state.patchState)")
            return
        }

        let basalEntries = Int(params.data[18])
        var basalSchedule: [BasalItem] = []
        for i in 0 ..< basalEntries {
            let value = params.data.toUInt64(offset: 19 + (i * 3), count: 3)
            let rate = Double(value >> 12) * 0.05
            let time = TimeInterval(minutes: Double(value & 0x0FFF))

            basalSchedule.append(BasalItem(start: time, rate: rate))
        }

        params.pumpManager.state.expirationTimer = params.data[6]
        params.pumpManager.state.alarmSettings = AlarmSettings(rawValue: params.data[7]) ?? .None
        params.pumpManager.state.hourlyMaxInsulin = params.data.toUInt16(offset: 10)
        params.pumpManager.state.dailyMaxInsulin = params.data.toUInt16(offset: 12)
        params.pumpManager.state.basal = basalSchedule
        params.pumpManager.state.basalSince = Date.now
        params.pumpManager.state.reservoirLevel = params.pumpManager.currentModel.index == 0 ? 200 : 300
        params.pumpManager.state.patchState = .active
        params.pumpManager.state.activatedAt = Date.now
        params.pumpManager.notifyStateDidUpdate()

        var response = Data()
        response.append(params.pumpManager.state.patchId.toData())
        response.append(Date.now.toMedtrumSeconds())
        response.append(BasalType.STANDARD.rawValue) // Patch just activated, no temp basal could have been activated
        response.append(UInt16(params.pumpManager.state.currentBaseBasalRate / 0.05).toData())
        response.append(params.pumpManager.state.patchSequence.toData())
        response.append(UInt16(params.pumpManager.state.patchId).toData())
        response.append(params.pumpManager.state.basalSince.toMedtrumSeconds())

        bluetoothManager.writeResponse(
            data: response,
            status: .ok,
            params.responseParam
        )

        bluetoothManager.writeResponse(
            data: MedtrumKitPackets.generateSynchronizePacket(state: params.pumpManager.state),
            status: .stateUpdate,
            params.updateParam
        )

        logger.info("Processed Activate message!")
    }

    static func parseDeactivatePacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        params.pumpManager.state.patchState = .filled
        params.pumpManager.state.reservoirLevel = params.pumpManager.currentModel.index == 0 ? 200 : 300
        params.pumpManager.state.suspendedSince = nil
        params.pumpManager.state.tempBasalStart = nil
        params.pumpManager.state.tempBasalPercentage = nil
        params.pumpManager.state.tempBasalDuration = nil
        params.pumpManager.notifyStateDidUpdate()

        var response = Data()
        response.append(params.pumpManager.state.patchSequence.toData())
        response.append(UInt16(params.pumpManager.state.patchId).toData())

        bluetoothManager.writeResponse(
            data: response,
            status: .ok,
            params.responseParam
        )
        logger.info("Processed Deactivate message!")
    }

    static func parseClearAlertPacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        bluetoothManager.writeResponse(
            data: Data(),
            status: .ok,
            params.responseParam
        )
        logger.info("Processed Clear alert message!")
    }

    private static func schedulePrimeUpdate(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        DispatchQueue.main.async {
            primeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                if let primeProgress = params.pumpManager.state.primeProgress {
                    params.pumpManager.state.primeProgress = primeProgress + 4

                    if primeProgress > 100 {
                        params.pumpManager.state.patchState = .ejected
                        params.pumpManager.state.primeProgress = nil

                        logger.info("Priming completed!")

                        primeTimer?.invalidate()
                        primeTimer = nil
                    }
                } else {
                    params.pumpManager.state.primeProgress = 1
                }

                params.pumpManager.notifyStateDidUpdate()

                bluetoothManager.writeResponse(
                    data: MedtrumKitPackets.generateSynchronizePacket(state: params.pumpManager.state),
                    status: .stateUpdate,
                    params.updateParam
                )
            }
        }
    }
}
