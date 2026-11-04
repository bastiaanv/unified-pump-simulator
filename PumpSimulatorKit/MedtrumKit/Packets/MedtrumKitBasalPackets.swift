import Foundation

extension MedtrumKitPackets {
    static func parseBasalSchedulePacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        guard acceptsDeliveryCommand(params, bluetoothManager, "basal schedule") else {
            return
        }

        let basalEntries = Int(params.data[5])
        var basalSchedule: [BasalItem] = []
        for i in 0 ..< basalEntries {
            let value = params.data.toUInt64(offset: 6 + (i * 3), count: 3)
            let rate = Double(value >> 12) * 0.05
            let time = TimeInterval(minutes: Double(value & 0x0FFF))

            basalSchedule.append(BasalItem(start: time, rate: rate))
        }

        let state = params.pumpManager.state
        // The segment so far is written at the rates it ran at
        state.basalProfileChanged(at: .now)
        state.basal = basalSchedule
        params.pumpManager.notifyStateDidUpdate()

        bluetoothManager.writeResponse(data: segmentAnswer(state), status: .ok, params.responseParam)
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

        // A running bolus stops with the rest of the delivery, as at a halt: its record first, then the segment's
        let delivered = endBolus(pumpManager: params.pumpManager, cause: bolusInterrupted)
        params.pumpManager.state.suspend(for: TimeInterval(minutes: Double(params.data[5])), at: .now)
        params.pumpManager.notifyStateDidUpdate()

        bluetoothManager.writeResponse(data: Data(), status: .ok, params.responseParam)
        bluetoothManager.writeResponse(
            data: MedtrumKitPackets.generateSynchronizePacket(
                state: params.pumpManager.state,
                completedBolus: delivered.map { CompletedBolus(cause: bolusInterrupted, delivered: $0) }
            ),
            status: .stateUpdate,
            params.updateParam
        )

        logger.info("Processed Suspend message!\(delivered.map { " Bolus cut at \($0)U" } ?? "")")
    }

    static func parseResumePacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        guard params.pumpManager.state.patchState.isSuspended else {
            logger.warning("Attempted resume during non-suspend state...")
            bluetoothManager.writeResponse(
                data: Data(),
                status: .invalidState,
                params.responseParam
            )
            return
        }

        let state = params.pumpManager.state
        state.resume(at: .now)
        params.pumpManager.notifyStateDidUpdate()

        // Laid out as the answer to CancelTempBasal: the segment the patch resumed with
        bluetoothManager.writeResponse(data: segmentAnswer(state), status: .ok, params.responseParam)
        bluetoothManager.writeResponse(
            data: MedtrumKitPackets.generateSynchronizePacket(state: params.pumpManager.state),
            status: .stateUpdate,
            params.updateParam
        )
        logger.info("Processed Resume message!")
    }

    static func parseStopTempBasalPacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        guard acceptsDeliveryCommand(params, bluetoothManager, "cancel temp basal") else {
            return
        }

        let state = params.pumpManager.state
        if !state.isDeliveringBasal || state.tempBasalRate == nil {
            bluetoothManager.skipFault("no temp basal to cancel")
        }
        state.cancelTempBasal(at: .now)
        params.pumpManager.notifyStateDidUpdate()

        // The schedule's segment that took over, and the record of the temp basal it ended
        bluetoothManager.writeResponse(data: segmentAnswer(state), status: .ok, params.responseParam)
        logger.info("Processed Stop TempBasal message!")
    }

    static func parseTempBasalPacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        guard params.pumpManager.state.patchState == .active else {
            logger.warning("Rejecting temp basal during non-active state...")
            bluetoothManager.writeResponse(
                data: Data(),
                status: .invalidState,
                params.responseParam
            )
            return
        }

        let currentRate = params.pumpManager.state.currentBaseBasalRate
        guard currentRate > 0 else {
            bluetoothManager.writeResponse(data: Data(), status: .invalidState, params.responseParam)
            logger.info("Cannot set temp basal without basal")
            return
        }

        let rate = Double(params.data.toUInt16(offset: 5)) * 0.05
        let duration = params.data.toUInt16(offset: 7)

        let state = params.pumpManager.state
        state.setTempBasal(rate: rate, duration: TimeInterval(minutes: Double(duration)), at: .now)
        params.pumpManager.notifyStateDidUpdate()

        // The temp basal that started, and the record of the segment it ended
        bluetoothManager.writeResponse(data: segmentAnswer(state), status: .ok, params.responseParam)
        logger.info("Processed TempBasal message!")
    }

    /// Whether the patch takes a delivery command it may have nothing to run for - a cancel, a new schedule. It does
    /// while it runs or is halted (answered as "nothing to do" if so); one stopped, or a base with no patch activated -
    /// set up, or restarted - refuses it with code 8, the refusal real patches answer a command they can't run with.
    /// Answered here if refused.
    static func acceptsDeliveryCommand(
        _ params: MedtrumKitPacketRequest,
        _ bluetoothManager: MedtrumKitBluetoothManager,
        _ what: String
    ) -> Bool {
        let state = params.pumpManager.state
        guard state.patchState == .stopped || state.patchState.rawValue < PatchState.active.rawValue else {
            return true
        }

        logger.warning("Rejecting \(what) in state \(state.patchState.title): no patch running")
        bluetoothManager.writeResponse(data: Data(), status: .invalidState, params.responseParam)
        return false
    }

    /// The answer to the commands that start a basal segment: its type, rate, the record of the segment it replaced
    /// (`basalSequence`), the patch id and its start
    static func segmentAnswer(_ state: MedtrumKitState) -> Data {
        // Suspended, nothing runs: the schedule as it would resume
        let delivering = state.isDeliveringBasal

        var response = Data([delivering ? state.segmentType.rawValue : BasalType.STANDARD.rawValue])
        response.append(UInt16(((delivering ? state.segmentRate : state.currentBaseBasalRate) / 0.05).rounded()).toData())
        response.append(state.basalSequence.toData())
        response.append(UInt16(truncatingIfNeeded: state.patchId).toData())
        response.append((delivering ? state.basalSince : Date.now).toMedtrumSeconds())
        return response
    }
}
