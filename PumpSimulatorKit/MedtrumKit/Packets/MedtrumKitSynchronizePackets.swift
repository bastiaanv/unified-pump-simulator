import Foundation

extension MedtrumKitPackets {
    /// The 30 s heartbeat, on the pump manager's queue
    static var synchronizeTimer: DispatchSourceTimer?

    /// Sends a status update to the subscribed phone - nil while none is
    private static var sendStatus: ((CompletedBolus?) -> Void)?

    /// A bolus that just ended, which the next notification tells of once
    struct CompletedBolus {
        /// 0 delivered in full, 32 cancelled, 9 cut by a halt
        let cause: UInt8
        let delivered: Double
    }

    static func parseSynchronizePacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        bluetoothManager.writeResponse(
            data: generateSynchronizePacket(state: params.pumpManager.state, longVersion: true),
            status: .ok,
            params.responseParam
        )
        logger.info("Processed Synchronized message!")
    }

    static func scheduleUpdates(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        synchronizeTimer?.cancel()

        sendStatus = { completedBolus in
            params.pumpManager.advanceDelivery()
            bluetoothManager.writeResponse(
                data: generateSynchronizePacket(state: params.pumpManager.state, completedBolus: completedBolus),
                status: .stateUpdate,
                params.updateParam
            )
        }

        synchronizeTimer = repeatingTimer(on: params.pumpManager.queue, every: 30.0) {
            sendStatus?(nil)
            logger.info("State update send!")
        }
    }

    /// A notification now, rather than at the next heartbeat - carrying the completion of a bolus that just ended
    static func sendStatusUpdate(completedBolus: CompletedBolus? = nil) {
        sendStatus?(completedBolus)
    }

    static func unscheduleUpdates() {
        synchronizeTimer?.cancel()
        synchronizeTimer = nil
        sendStatus = nil
    }

    /// A status: the answer to Synchronize (`longVersion`), or a notification.
    ///
    /// As real patches send them: a notification carries the bolus field only while a bolus runs, and once as it ends
    /// (`completedBolus`); a full status always does while active, repeating the last bolus's completion between
    /// boluses. The basal field is there only while a basal segment runs - not while suspended or halted. The storage
    /// field names the newest record whenever the patch is past setup.
    static func generateSynchronizePacket(
        state: MedtrumKitState,
        longVersion: Bool = false,
        completedBolus: CompletedBolus? = nil
    ) -> Data {
        var fieldFlags: UInt16 = 0
        var data = Data([])

        if state.patchState == .suspended, let suspendedSince = state.suspendedSince {
            fieldFlags |= Self.MASK_SUSPEND
            data.append(suspendedSince.toMedtrumSeconds())
        }

        if let completedBolus {
            fieldFlags |= Self.MASK_NORMAL_BOLUS
            data.append(bolusField(type: completedBolus.cause, completed: true, delivered: completedBolus.delivered))
        } else if state.isDeliveringBasal, state.isBolusRunning {
            fieldFlags |= Self.MASK_NORMAL_BOLUS
            data.append(bolusField(type: 0, completed: false, delivered: state.bolusProgress ?? 0))
        } else if longVersion, state.isDeliveringBasal {
            fieldFlags |= Self.MASK_NORMAL_BOLUS
            data.append(bolusField(type: state.lastBolusCause, completed: true, delivered: state.lastBolusDelivered))
        }

        // Extended bolus not support via sim

        if state.isDeliveringBasal {
            fieldFlags |= Self.MASK_BASAL

            let rateSteps = UInt64(min(0xFFF, (state.segmentRate / 0.05).rounded()))
            let deliveredSteps = UInt64(min(0xFFF, (state.segmentDelivered(until: .now) / 0.05).rounded()))

            var basalData = Data([state.segmentType.rawValue])
            basalData.append(state.basalSequence.toData())
            basalData.append(UInt16(truncatingIfNeeded: state.patchId).toData())
            basalData.append(state.basalSince.toMedtrumSeconds())
            basalData.append((deliveredSteps << 12 | rateSteps).toData(length: 3))

            data.append(basalData)
        }

        if state.patchState.rawValue < PatchState.active.rawValue {
            fieldFlags |= Self.MASK_SETUP
            data.append(state.primeProgress ?? 0)
        }

        fieldFlags |= Self.MASK_RESERVOIR
        data.append(UInt16(state.reservoirLevel / 0.05).toData())

        if state.patchState.rawValue >= PatchState.active.rawValue,
           let activatedAt = state.activatedAt, longVersion
        {
            fieldFlags |= Self.MASK_START_TIME
            data.append(activatedAt.toMedtrumSeconds())
        }

        if state.patchState.rawValue >= PatchState.active.rawValue, longVersion {
            fieldFlags |= Self.MASK_BATTERY

            let value = UInt64(state.voltageA * 512) + UInt64(state.voltageB * 512) << 12
            data.append(value.toData(length: 3))
        }

        if state.patchState.rawValue >= PatchState.active.rawValue {
            fieldFlags |= Self.MASK_STORAGE
            data.append(state.recordLog.newestWritten.toData())
            data.append(UInt16(truncatingIfNeeded: state.patchId).toData())
        }

        if state.patchState == .hourlyMaxSuspended || state.patchState == .dailyMaxSuspended {
            fieldFlags |= Self.MASK_ALARM

            var value: UInt16 = 0
            if state.patchState == .hourlyMaxSuspended {
                value += AlarmState.HourlyMaxSuspended.rawValue
            } else if state.patchState == .dailyMaxSuspended {
                value += AlarmState.DailyMaxSuspended.rawValue
            }

            data.append(value.toData())
            data.append(UInt16(0).toData()) // Unused parameter
        }

        var output = Data()
        output.append(state.patchState.rawValue)
        output.append(fieldFlags.toData())
        output.append(data)

        if output.count < 14 {
            output.append(Data(repeating: 0, count: 14 - output.count))
        }

        return output
    }

    /// Type (the completion cause) in the low 7 bits, completed in the high one, then the amount delivered so far
    private static func bolusField(type: UInt8, completed: Bool, delivered: Double) -> Data {
        var bolusData = Data([type & 0x7F | (completed ? 0x80 : 0x00)])
        bolusData.append(UInt16(max(0, (delivered / 0.05).rounded())).toData())
        return bolusData
    }

    private static let MASK_SUSPEND: UInt16 = 0x01
    private static let MASK_NORMAL_BOLUS: UInt16 = 0x02
    private static let MASK_UNUSED_EXTENDED_BOLUS: UInt16 = 0x04
    private static let MASK_BASAL: UInt16 = 0x08
    private static let MASK_SETUP: UInt16 = 0x10
    private static let MASK_RESERVOIR: UInt16 = 0x20
    private static let MASK_START_TIME: UInt16 = 0x40
    private static let MASK_BATTERY: UInt16 = 0x80
    private static let MASK_STORAGE: UInt16 = 0x100
    private static let MASK_ALARM: UInt16 = 0x200
    private static let MASK_UNUSED_AGE: UInt16 = 0x400
    private static let MASK_UNUSED_MAGNETO_PLACE: UInt16 = 0x800
    private static let MASK_UNUSED_CGM: UInt16 = 0x1000
    private static let MASK_UNUSED_COMMAND_CONFIRM: UInt16 = 0x2000
    private static let MASK_UNUSED_AUTO_STATUS: UInt16 = 0x4000
    private static let MASK_UNUSED_LEGACY: UInt16 = 0x8000
}
