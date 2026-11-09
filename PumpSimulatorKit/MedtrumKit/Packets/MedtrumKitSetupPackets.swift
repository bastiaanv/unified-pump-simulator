import Foundation

extension MedtrumKitPackets {
    /// Priming's progress, on the pump manager's queue
    static var primeTimer: DispatchSourceTimer?

    static func parsePrimePacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        // Only a patch being filled primes: not one priming or activated already, nor a stopped one still answering
        guard params.pumpManager.state.isFillable else {
            logger.warning("Rejecting prime in state \(params.pumpManager.state.patchState.title): not a patch being filled")
            bluetoothManager.writeResponse(data: Data(), status: .invalidState, params.responseParam)
            return
        }

        params.pumpManager.state.clearDelivery()
        params.pumpManager.state.patchState = .priming
        params.pumpManager.state.primeProgress = 1
        params.pumpManager.notifyStateDidUpdate()

        bluetoothManager.writeResponse(
            data: Data(),
            status: .ok,
            params.responseParam
        )

        schedulePrimeUpdate(params, bluetoothManager)
    }

    static func parseActivatePacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        // Only a primed patch activates: one activated already - its answer lost, say - refuses a second Activate
        guard [.primed, .ejected].contains(params.pumpManager.state.patchState) else {
            logger.warning("Rejecting activate in state \(params.pumpManager.state.patchState.title): not primed")
            bluetoothManager.writeResponse(data: Data(), status: .invalidState, params.responseParam)
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
        let now = Date.now
        let state = params.pumpManager.state
        state.basal = basalSchedule
        // The reservoir holds what it was filled with
        // A new patch: a new id - the one a base that restarted announced - its records from 1 on
        let patchId = state.baseResetAt != nil ? state.patchId : params.pumpManager.nextPatchId()
        state.baseResetAt = nil
        state.activate(patchId: patchId, at: now)
        params.pumpManager.patchFaults.update { $0.recordFaultNumber = nil }
        params.pumpManager.callOffPendingOcclusion("a new patch activated")
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
        params.pumpManager.callOffPendingOcclusion("the patch is stopped")

        // The newest record, as the patch stops
        var response = Data()
        response.append(params.pumpManager.state.recordLog.newestWritten.toData())
        response.append(UInt16(truncatingIfNeeded: params.pumpManager.state.patchId).toData())

        // The old patch may go on answering a while - stopped, its id and records - before the base is on a new one
        let lingers = params.pumpManager.patchFaults.current.stoppedPatchSeconds
        if params.pumpManager.state.isFillable {
            // Already a new patch, being filled: a stop sent again leaves it as it is
            logger.info("StopPatch with no patch running: the new patch is left as it is")
        } else if lingers > 0 {
            let state = params.pumpManager.state
            state.patchState = .stopped
            state.suspendedSince = nil
            state.suspendedDuration = nil
            state.stoppedPatchUntil = Date.now.addingTimeInterval(lingers)
            logger.warning("[FAULT] The stopped patch goes on answering for \(Int(lingers)) s, then the base is on a new one")
            params.pumpManager.notifyStateDidUpdate()
        } else {
            params.pumpManager.putNewPatch()
        }

        bluetoothManager.writeResponse(
            data: response,
            status: .ok,
            params.responseParam
        )
        logger.info("Processed Deactivate message!")
    }

    /// SetPatch: the patch's settings - alarm setting (1), hourly and daily maximum (2 each), expiration timer (1), then
    /// five auto-mode values nobody uses. Answered with nothing but success, as MedtrumKit and AndroidAPS read it.
    static func parseSetPatchPacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        guard params.data.count >= 10 else {
            logger.warning("SetPatch message too short: \(params.data.hexString())")
            bluetoothManager.writeResponse(data: Data(), status: .invalidState, params.responseParam)
            return
        }

        let state = params.pumpManager.state
        state.alarmSettings = AlarmSettings(rawValue: params.data[4]) ?? state.alarmSettings
        state.hourlyMaxInsulin = params.data.toUInt16(offset: 5)
        state.dailyMaxInsulin = params.data.toUInt16(offset: 7)
        state.expirationTimer = params.data[9]
        params.pumpManager.notifyStateDidUpdate()

        bluetoothManager.writeResponse(data: Data(), status: .ok, params.responseParam)
        logger.info("Processed SetPatch message!")
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
