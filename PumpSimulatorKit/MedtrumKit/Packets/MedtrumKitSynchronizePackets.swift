import Foundation

extension MedtrumKitPackets {
    static var synchronizeTimer: Timer?

    static func parseSynchronizePacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        bluetoothManager.writeResponse(
            data: generateSynchronizePacket(state: params.pumpManager.state, longVersion: true),
            status: .ok,
            params.responseParam
        )
        logger.info("Processed Synchronized message!")
    }

    static func scheduleUpdates(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        if let synchronizeTimer {
            synchronizeTimer.invalidate()
            Self.synchronizeTimer = nil
        }

        DispatchQueue.main.async {
            synchronizeTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
                bluetoothManager.writeResponse(
                    data: generateSynchronizePacket(state: params.pumpManager.state),
                    status: .stateUpdate,
                    params.updateParam
                )

                logger.info("State update send!")
            }
        }
    }

    static func unscheduleUpdates() {
        synchronizeTimer?.invalidate()
        synchronizeTimer = nil
    }

    static func generateSynchronizePacket(state: MedtrumKitState, longVersion: Bool = false) -> Data {
        var fieldFlags: UInt16 = 0
        var data = Data([])

        if state.patchState == .suspended, let suspendedSince = state.suspendedSince {
            fieldFlags |= Self.MASK_SUSPEND
            data.append(suspendedSince.toMedtrumSeconds())
        }

        if state.patchState == .active, let bolusProgress = state.bolusProgress, let bolusTotal = state.bolusTotal {
            fieldFlags |= Self.MASK_NORMAL_BOLUS

            let bolusType = 0x00
            let bolusCompleted = bolusProgress >= bolusTotal

            var bolusData = Data([UInt8(bolusType & 0x7F | (bolusCompleted ? 0x80 : 0x00))])
            bolusData.append(UInt16(bolusProgress / 0.05).toData())

            data.append(bolusData)
        }

        // Extended bolus not support via sim

        if state.patchState == .active {
            fieldFlags |= Self.MASK_BASAL

            var basalData = Data([
                BasalType.NONE.rawValue,
                0x00,
                0x00, // Sequence
            ])
            basalData.append(UInt16(state.patchId).toData())

            let currentBaseBasalRate = UInt64(state.currentBaseBasalRate / 0.05)

            if let tempBasalPercentage = state.tempBasalPercentage, let tempBasalStart = state.tempBasalStart {
                basalData[0] = BasalType.ABSOLUTE_TEMP.rawValue
                basalData.append(tempBasalStart.toMedtrumSeconds())

                let rateDelivery = (currentBaseBasalRate * UInt64(tempBasalPercentage / 100))
                basalData.append(rateDelivery.toData(length: 3))

            } else {
                basalData[0] = BasalType.STANDARD.rawValue
                basalData.append(state.basalSince.toMedtrumSeconds())
                basalData.append(currentBaseBasalRate.toData(length: 3))
            }

            data.append(basalData)
        }

        if state.patchState.rawValue < PatchState.active.rawValue {
            fieldFlags |= Self.MASK_SETUP
            data.append(state.primeProgress ?? 0)
        }

        if state.patchState == .active {
            fieldFlags |= Self.MASK_RESERVOIR
            data.append(UInt16(state.reservoirLevel / 0.05).toData())
        }

        if state.patchState == .active, let activatedAt = state.activatedAt, longVersion {
            fieldFlags |= Self.MASK_START_TIME
            data.append(activatedAt.toMedtrumSeconds())
        }

        if state.patchState == .active, longVersion {
            fieldFlags |= Self.MASK_BATTERY

            let value = UInt64(state.voltageA * 512) + UInt64(state.voltageB * 512) << 12
            data.append(value.toData(length: 3))

            fieldFlags |= Self.MASK_STORAGE
            data.append(state.patchSequence.toData())
            data.append(UInt16(state.patchId).toData())
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
