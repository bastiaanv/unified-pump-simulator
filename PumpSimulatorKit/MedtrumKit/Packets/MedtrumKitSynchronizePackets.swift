import Foundation

extension MedtrumKitPackets {
    /// The 30 s heartbeat, on the pump manager's queue
    static var synchronizeTimer: DispatchSourceTimer?

    /// Sends a status update to the subscribed phone - nil while none is
    private static var sendStatus: ((CompletedBolus?, Bool) -> Void)?

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

        sendStatus = { completedBolus, haltNotification in
            params.pumpManager.advanceDelivery()
            bluetoothManager.writeResponse(
                data: generateSynchronizePacket(
                    state: params.pumpManager.state,
                    completedBolus: completedBolus,
                    haltNotification: haltNotification
                ),
                status: .stateUpdate,
                params.updateParam
            )
        }

        synchronizeTimer = repeatingTimer(on: params.pumpManager.queue, every: 30.0) {
            sendStatus?(nil, false)
            logger.info("State update send!")
        }
    }

    /// A notification now, rather than at the next heartbeat - carrying the completion of a bolus that just ended.
    /// `haltNotification`: the one announcing that the patch ran dry (see `generateSynchronizePacket`).
    static func sendStatusUpdate(completedBolus: CompletedBolus? = nil, haltNotification: Bool = false) {
        sendStatus?(completedBolus, haltNotification)
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
    /// boluses. The basal field is there only while a basal segment runs - not while suspended or halted, except in the
    /// notification announcing that the patch ran dry (`haltNotification`, state 98): there it is its type byte alone,
    /// none (0), and the CGM field's 5 bytes follow - a real patch's notification, byte for byte (device 2026-10-26).
    /// The full statuses after it have no basal field, and carry the patch age and the magneto placement (device
    /// 2026-11-03). The storage field names the newest record whenever the patch is past setup, the alarm field is
    /// there while an alarm is (`alarmFlags`).
    static func generateSynchronizePacket(
        state: MedtrumKitState,
        longVersion: Bool = false,
        completedBolus: CompletedBolus? = nil,
        haltNotification: Bool = false
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

        let runDry = state.patchState == .reservoirEmpty
        let shortBasal = runDry && haltNotification && !longVersion
        if shortBasal {
            // Device 2026-10-26: `62 2813 | 00 | 0000 | 6b06 1201 | 0401 0000 | 00×5`
            fieldFlags |= Self.MASK_BASAL
            data.append(BasalType.NONE.rawValue)
        } else if state.isDeliveringBasal {
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
        data.append(UInt16((state.insulinLeft() / 0.05).rounded()).toData())

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

        // A base that restarted: state none, the next patch's id and no record yet, its age since the restart -
        // device 2026-09-19, age 1 s
        let baseReset = state.patchState == .none ? state.baseResetAt : nil
        if baseReset != nil {
            fieldFlags |= Self.MASK_STORAGE
            data.append(UInt16(0).toData())
            data.append(UInt16(truncatingIfNeeded: state.patchId).toData())
        }

        let alarms = alarmFlags(state)
        if alarms != 0 {
            fieldFlags |= Self.MASK_ALARM
            data.append(alarms.toData())
            data.append(UInt16(0).toData()) // Unused parameter
        }

        // The age: of a restarted base since its restart, of a patch since its activation - real patches count from
        // their first power-up on the base
        let ageSince = baseReset ?? (runDry && longVersion ? state.activatedAt : nil)
        if let ageSince {
            fieldFlags |= Self.MASK_AGE
            data.append(UInt32(clamping: Int(max(0, Date.now.timeIntervalSince(ageSince)))).toData())
        }

        if runDry, longVersion {
            // Its value is not modelled
            fieldFlags |= Self.MASK_MAGNETO_PLACE
            data.append(UInt16(0).toData())
        }

        if shortBasal {
            fieldFlags |= Self.MASK_UNUSED_CGM
            data.append(Data(count: 5))
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

    /// The alarms active, one bit each as the alarm records name them: 2 low reservoir, 4 delivery suspended (the
    /// hourly or daily maximum), 6 occlusion, 8 reservoir empty. Bits 2 and 8 are from real patches' statuses
    /// (0x0104 run dry), 6 from a live occlusion's; 4 is the bit of a suspend's alarm record.
    ///
    /// A stopped patch keeps the alarms it had, and adds bit 14 - seen in the statuses of stopped patches only, what it
    /// means is not known (device 2026-11-03 19:52:44: bits 2, 8 and 14 after running dry).
    static func alarmFlags(_ state: MedtrumKitState) -> UInt16 {
        guard state.patchState.rawValue >= PatchState.active.rawValue else {
            return 0
        }

        var bits: [UInt8] = []
        if state.lowReservoirAlarmed || state.insulinLeft() < MedtrumKitState.lowReservoirWarning {
            bits.append(MedtrumKitRecord.alarmLowReservoir)
        }

        let alarmsOf = state.patchState == .stopped ? state.haltedAs : state.patchState
        if state.patchState == .stopped {
            bits.append(14)
        }

        switch alarmsOf {
        case .dailyMaxSuspended,
             .hourlyMaxSuspended:
            bits.append(MedtrumKitRecord.alarmSuspended)
        case .occlusion:
            bits.append(MedtrumKitRecord.alarmOcclusion)
        case .reservoirEmpty:
            bits.append(MedtrumKitRecord.alarmReservoirEmpty)
        default:
            break
        }

        return bits.reduce(0) { $0 | UInt16(1) << $1 }
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
    private static let MASK_AGE: UInt16 = 0x400
    private static let MASK_MAGNETO_PLACE: UInt16 = 0x800
    private static let MASK_UNUSED_CGM: UInt16 = 0x1000
    private static let MASK_UNUSED_COMMAND_CONFIRM: UInt16 = 0x2000
    private static let MASK_UNUSED_AUTO_STATUS: UInt16 = 0x4000
    private static let MASK_UNUSED_LEGACY: UInt16 = 0x8000
}
