import Foundation

extension MedtrumKitPackets {
    static func parseBasalSchedulePacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        let basalEntries = Int(params.data[5])
        var basalSchedule: [BasalItem] = []
        for i in 0 ..< basalEntries {
            let value = params.data.toUInt64(offset: 6 + (i * 3), count: 3)
            let rate = Double(value >> 12) * 0.05
            let time = TimeInterval(minutes: Double(value & 0x0FFF))

            basalSchedule.append(BasalItem(start: time, rate: rate))
        }

        params.pumpManager.state.basal = basalSchedule
        params.pumpManager.notifyStateDidUpdate()

        let rate = params.pumpManager.state.currentBaseBasalRate
        var response = Data([BasalType.STANDARD.rawValue])
        response.append(UInt16(rate / 0.05).toData())
        response.append(params.pumpManager.state.patchSequence.toData())
        response.append(UInt16(params.pumpManager.state.patchId).toData())
        response.append(Date.now.toMedtrumSeconds())

        bluetoothManager.writeResponse(data: response, status: .ok, params.responseParam)
        logger.info("Processed Basal schedule message!")
    }

    static func parseSuspendPacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        guard params.pumpManager.state.patchState == .active else {
            logger.warning("Attempted suspend during non-active state...")
            bluetoothManager.writeResponse(
                data: Data(),
                status: .invalidState,
                params.responseParam
            )
            return
        }

        params.pumpManager.state.patchState = .suspended
        params.pumpManager.state.suspendedSince = Date.now
        params.pumpManager.state.suspendedDuration = TimeInterval(minutes: Double(params.data[5]))
        params.pumpManager.state.tempBasalStart = nil
        params.pumpManager.state.tempBasalPercentage = nil
        params.pumpManager.state.tempBasalDuration = nil
        params.pumpManager.notifyStateDidUpdate()

        bluetoothManager.writeResponse(data: Data(), status: .ok, params.responseParam)
        bluetoothManager.writeResponse(
            data: MedtrumKitPackets.generateSynchronizePacket(state: params.pumpManager.state),
            status: .stateUpdate,
            params.updateParam
        )

        logger.info("Processed Suspend message!")
    }

    static func parseResumePacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        guard params.pumpManager.state.patchState == .suspended else {
            logger.warning("Attempted resume during non-suspend state...")
            bluetoothManager.writeResponse(
                data: Data(),
                status: .invalidState,
                params.responseParam
            )
            return
        }
        
        params.pumpManager.state.patchState = .active
        params.pumpManager.state.suspendedSince = nil
        params.pumpManager.state.tempBasalStart = nil
        params.pumpManager.state.tempBasalPercentage = nil
        params.pumpManager.state.tempBasalDuration = nil
        params.pumpManager.notifyStateDidUpdate()

        bluetoothManager.writeResponse(data: Data(), status: .ok, params.responseParam)
        bluetoothManager.writeResponse(
            data: MedtrumKitPackets.generateSynchronizePacket(state: params.pumpManager.state),
            status: .stateUpdate,
            params.updateParam
        )
        logger.info("Processed Resume message!")
    }

    static func parseStopTempBasalPacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        params.pumpManager.state.patchState = .active
        params.pumpManager.state.suspendedSince = nil
        params.pumpManager.state.tempBasalStart = nil
        params.pumpManager.state.tempBasalDuration = nil
        params.pumpManager.state.tempBasalPercentage = nil
        params.pumpManager.notifyStateDidUpdate()

        let rate = params.pumpManager.state.currentBaseBasalRate

        var response = Data([BasalType.ABSOLUTE_TEMP.rawValue])
        response.append(UInt16(rate / 0.05).toData())
        response.append(params.pumpManager.state.patchSequence.toData())
        response.append(UInt16(params.pumpManager.state.patchId).toData())
        response.append(Date.now.toMedtrumSeconds())

        bluetoothManager.writeResponse(data: response, status: .ok, params.responseParam)
        logger.info("Processed TempBasal message!")
    }

    static func parseTempBasalPacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        let currentRate = params.pumpManager.state.currentBaseBasalRate
        guard currentRate > 0 else {
            bluetoothManager.writeResponse(data: Data(), status: .invalidState, params.responseParam)
            logger.info("Cannot set temp basal without basal")
            return
        }

        let rate = Double(params.data.toUInt16(offset: 5)) * 0.05
        let duration = params.data.toUInt16(offset: 7)

        params.pumpManager.state.patchState = .active
        params.pumpManager.state.suspendedSince = nil
        params.pumpManager.state.tempBasalStart = Date.now
        params.pumpManager.state.tempBasalDuration = TimeInterval(minutes: Double(duration))
        params.pumpManager.state.tempBasalPercentage = UInt16(rate / currentRate * 100)
        params.pumpManager.notifyStateDidUpdate()

        var response = Data([BasalType.ABSOLUTE_TEMP.rawValue])
        response.append(UInt16(rate / 0.05).toData())
        response.append(params.pumpManager.state.patchSequence.toData())
        response.append(UInt16(params.pumpManager.state.patchId).toData())
        response.append(Date.now.toMedtrumSeconds())

        bluetoothManager.writeResponse(data: response, status: .ok, params.responseParam)
        logger.info("Processed TempBasal message!")
    }
}
