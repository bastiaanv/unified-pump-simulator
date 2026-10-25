import Foundation

extension MedtrumKitPackets {
    /// Priming's progress, on the pump manager's queue
    static var primeTimer: DispatchSourceTimer?

    static func parsePrimePacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        params.pumpManager.state.patchState = .priming
        params.pumpManager.state.primeProgress = 1
        params.pumpManager.state.tempBasalStart = nil
        params.pumpManager.state.tempBasalRate = nil
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
        let now = Date.now
        let state = params.pumpManager.state
        state.basal = basalSchedule
        state.reservoirLevel = params.pumpManager.currentModel.index == 0 ? 200 : 300
        // A new patch: a new id, its records from 1 on
        state.activate(patchId: params.pumpManager.nextPatchId(), at: now)
        state.patchState = .active
        state.activatedAt = now
        params.pumpManager.notifyStateDidUpdate()

        var response = Data()
        response.append(state.patchId.toData())
        response.append(now.toMedtrumSeconds())
        response.append(BasalType.STANDARD.rawValue) // Patch just activated, no temp basal could have been activated
        response.append(UInt16(state.currentBaseBasalRate / 0.05).toData())
        response.append(state.basalSequence.toData())
        response.append(UInt16(truncatingIfNeeded: state.patchId).toData())
        response.append(state.basalSince.toMedtrumSeconds())

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
        // What was running ends here: its records are the last of this patch
        if let delivered = endBolus(pumpManager: params.pumpManager, cause: bolusInterrupted) {
            logger.info("Bolus cut by the stop at \(delivered)U")
        }
        params.pumpManager.state.stop(at: .now)

        // The newest record, as the patch stops
        var response = Data()
        response.append(params.pumpManager.state.recordLog.newestWritten.toData())
        response.append(UInt16(truncatingIfNeeded: params.pumpManager.state.patchId).toData())

        params.pumpManager.state.patchState = .filled
        params.pumpManager.state.reservoirLevel = params.pumpManager.currentModel.index == 0 ? 200 : 300
        params.pumpManager.state.suspendedSince = nil
        params.pumpManager.state.tempBasalStart = nil
        params.pumpManager.state.tempBasalRate = nil
        params.pumpManager.state.tempBasalDuration = nil
        params.pumpManager.notifyStateDidUpdate()

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

    static func stopPrimeTimer() {
        primeTimer?.cancel()
        primeTimer = nil
    }

    private static func schedulePrimeUpdate(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        stopPrimeTimer()
        primeTimer = repeatingTimer(on: params.pumpManager.queue, every: 1.0) {
            if let primeProgress = params.pumpManager.state.primeProgress {
                params.pumpManager.state.primeProgress = primeProgress + 4

                if primeProgress > 100 {
                    params.pumpManager.state.patchState = .ejected
                    params.pumpManager.state.primeProgress = nil

                    logger.info("Priming completed!")

                    stopPrimeTimer()
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
