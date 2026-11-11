import Foundation

extension MedtrumKitPackets {
    /// Delivers the running bolus, on the pump manager's queue
    static var bolusRun: BolusRun?
    private static let supportedBolusVolumes = (1 ... 600).map { Double($0) / 20 }

    /// Bolus causes, as the completion notification's type and the record carry them
    static let bolusCompleted: UInt8 = 0
    static let bolusCancelled: UInt8 = 32
    static let bolusInterrupted: UInt8 = 9

    static func startBolus(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        // The amount in the patch's 0.05 U steps: all the command carries
        let steps = params.data.toUInt16(offset: 5)
        let refuse = { (why: String) in
            params.pumpManager.noteReceivedDose("SetBolus", steps: steps, unit: "U", result: "refused (code 8): \(why)")
            params.pumpManager.notifyStateDidUpdate()
        }

        guard params.pumpManager.state.patchState == .active else {
            refuse("the patch is \(params.pumpManager.state.patchState.title)")
            logger.warning("Attempted startBolus during non-active state...")
            bluetoothManager.writeResponse(
                data: Data(),
                status: .invalidState,
                params.responseParam
            )
            return
        }

        // One bolus at a time: the running one's record is still to be written
        guard !params.pumpManager.state.isBolusRunning else {
            refuse("a bolus is running")
            logger.warning("Attempted startBolus while a bolus is running...")
            bluetoothManager.writeResponse(data: Data(), status: .invalidState, params.responseParam)
            return
        }

        // Nothing to deliver, or more than the patch takes: refused as real patches refuse a command they can't run -
        // what a real one answers to these is not on record
        guard steps > 0, steps <= MedtrumKitPumpManager.maximumBolusSteps else {
            refuse(steps == 0 ? "no amount" : "above the 30 U maximum")
            logger.warning("Rejecting a bolus of \(steps) steps: the patch takes 1 to \(MedtrumKitPumpManager.maximumBolusSteps)")
            bluetoothManager.writeResponse(data: Data(), status: .invalidState, params.responseParam)
            return
        }

        let amount = Double(steps) * 0.05
        let state = params.pumpManager.state
        let startTime = Date.now
        let recordNumber = state.startBolus(amount: amount, at: startTime)
        let runsDry = params.pumpManager.patchFaults.update { settings in
            let armed = settings.dryDuringNextBolus
            settings.dryDuringNextBolus = false
            return armed
        }
        let replaced = params.pumpManager.patchFaults.update { settings in
            let armed = settings.replaceDuringNextBolus
            settings.replaceDuringNextBolus = false
            return armed
        }
        if replaced {
            logger.warning("[FAULT] The base is put on a new patch 5 s into this bolus, the old one never stopped")
            let generation = params.pumpManager.patchFaults.generation
            params.pumpManager.queue.asyncAfter(deadline: .now() + 5) { [weak pumpManager = params.pumpManager] in
                // Not if the bolus is over, or the faults were disarmed since
                guard let pumpManager, pumpManager.state.bolusStart == startTime,
                      pumpManager.patchFaults.generation == generation
                else {
                    return
                }
                pumpManager.logger.warning("[FAULT] The base is on a new patch: the old one was never stopped")
                pumpManager.putNewPatch(announce: true)
            }
        }
        let bolusFaults = params.pumpManager.patchFaults.takeBolusFaults(for: amount)
        for note in bolusFaults.notes {
            logger.warning("[FAULT] \(note)")
        }
        if let stall = bolusFaults.stall {
            logger.warning(
                "[FAULT] This \(amount)U bolus stalls past \(stall.fromUnits)U: " +
                    params.pumpManager.patchFaults.current.bolusStall.description
            )
        }
        if runsDry {
            // What is left is half the bolus: it is cut there (`scheduleBolus`)
            let half = max(0.05, roundToSupportedBolusVolume(amount / 2))
            let segment = state.isDeliveringBasal ? state.segmentDelivered(until: startTime) : 0
            state.reservoirLevel = segment + half
            logger.warning("[FAULT] The reservoir holds \(half)U for this \(amount)U bolus: it runs dry halfway through")
        }
        // A real patch has delivered its first pulse by the time it answers
        state.bolusProgress = min(amount, 0.05)
        params.pumpManager.noteReceivedDose(
            "SetBolus",
            steps: steps,
            unit: "U",
            result: "started, its answer names record #\(recordNumber)"
        )
        params.pumpManager.notifyStateDidUpdate()

        // The record number the bolus gets if the patch writes nothing else before it ends, and when it started
        var response = recordNumber.toData()
        response.append(UInt16(truncatingIfNeeded: state.patchId).toData())
        response.append(startTime.toMedtrumSeconds())

        bluetoothManager.writeResponse(
            data: response,
            status: .ok,
            params.responseParam
        )

        scheduleBolus(
            amount: amount,
            startTime: startTime,
            stall: bolusFaults.stall,
            occlusionMinutes: bolusFaults.occlusionMinutes,
            pumpManager: params.pumpManager
        )

        logger.info("Processed Start bolus message! \(amount)U, the answer names record #\(recordNumber)")
    }

    static func stopBolus(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        guard acceptsDeliveryCommand(params, bluetoothManager, "cancel bolus") else {
            return
        }

        // A cancel with no bolus running is answered as a success, as real patches do
        guard let delivered = endBolus(pumpManager: params.pumpManager, cause: bolusCancelled) else {
            bluetoothManager.skipFault("no bolus to cancel")
            bluetoothManager.writeResponse(data: Data(), status: .ok, params.responseParam)
            logger.info("Processed Stop bolus message, no bolus was running")
            return
        }

        bluetoothManager.writeResponse(
            data: Data(),
            status: .ok,
            params.responseParam
        )

        // Then the completion, with what was delivered
        sendStatusUpdate(completedBolus: CompletedBolus(cause: bolusCancelled, delivered: delivered))
        logger.info("Processed Stop bolus message! \(delivered)U delivered")
    }

    /// Ends the running bolus short - cancelled, or cut by a halt, a suspend or a stop - and writes its record. What it
    /// delivered, nil if none was running.
    static func endBolus(pumpManager: MedtrumKitPumpManager, cause: UInt8) -> Double? {
        let state = pumpManager.state
        guard state.isBolusRunning else {
            return nil
        }

        stopBolusTimer()

        let delivered = state.bolusProgress ?? 0
        state.finishBolus(delivered: delivered, cause: cause, at: .now)
        pumpManager.notifyStateDidUpdate()

        return delivered
    }

    static func stopBolusTimer() {
        bolusRun?.cancel()
        bolusRun = nil
    }

    /// The patch's pace: a 0.05 U step every 2 s - 1.5 U a minute
    static let bolusStepUnits = 0.05
    static let bolusStepInterval: TimeInterval = 2

    private static func scheduleBolus(
        amount: Double,
        startTime: Date,
        stall: BolusStallPlan?,
        occlusionMinutes: Double?,
        pumpManager: MedtrumKitPumpManager
    ) {
        stopBolusTimer()
        let run = BolusRun(
            amount: amount,
            startTime: startTime,
            stall: stall,
            occlusionMinutes: occlusionMinutes,
            pumpManager: pumpManager
        )
        bolusRun = run
        run.start()
    }

    /// A timer firing on `queue` every `interval`, the first time `interval` from now
    static func repeatingTimer(
        on queue: DispatchQueue,
        every interval: TimeInterval,
        _ handler: @escaping () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    private static func roundToSupportedBolusVolume(_ amount: Double) -> Double {
        supportedBolusVolumes.last(where: { $0 <= amount }) ?? 0
    }
}
