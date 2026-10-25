import Foundation

extension MedtrumKitPackets {
    /// Delivers the running bolus, on the pump manager's queue
    static var bolusTimer: DispatchSourceTimer?
    private static let supportedBolusVolumes = (1 ... 600).map { Double($0) / 20 }

    /// Bolus causes, as the completion notification's type and the record carry them
    static let bolusCompleted: UInt8 = 0
    static let bolusCancelled: UInt8 = 32
    static let bolusInterrupted: UInt8 = 9

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

        // One bolus at a time: the running one's record is still to be written
        guard !params.pumpManager.state.isBolusRunning else {
            logger.warning("Attempted startBolus while a bolus is running...")
            bluetoothManager.writeResponse(data: Data(), status: .invalidState, params.responseParam)
            return
        }

        let amount = Double(params.data.toUInt16(offset: 5)) * 0.05
        let state = params.pumpManager.state
        let startTime = Date.now
        let recordNumber = state.startBolus(amount: amount, at: startTime)
        // A real patch has delivered its first pulse by the time it answers
        state.bolusProgress = min(amount, 0.05)
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

        scheduleBolus(amount: amount, startTime: startTime, pumpManager: params.pumpManager)

        logger.info("Processed Start bolus message! \(amount)U, the answer names record #\(recordNumber)")
    }

    static func stopBolus(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        // A cancel with no bolus running is answered as a success, as real patches do
        guard let delivered = endBolus(pumpManager: params.pumpManager, cause: bolusCancelled) else {
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
        bolusTimer?.cancel()
        bolusTimer = nil
    }

    private static func scheduleBolus(amount: Double, startTime: Date, pumpManager: MedtrumKitPumpManager) {
        // 1.5 unit per minute
        let duration = amount / 1.5 * TimeInterval(minutes: 1)
        let endTime = startTime.addingTimeInterval(duration)
        let originalReservoirLevel = pumpManager.state.reservoirLevel

        stopBolusTimer()
        bolusTimer = repeatingTimer(on: pumpManager.queue, every: 2.0) {
            let state = pumpManager.state
            // Ended meanwhile - cancelled, cut short - or another patch
            guard state.isBolusRunning, state.bolusStart == startTime else {
                stopBolusTimer()
                return
            }

            let progressPercentage = Date.now.timeIntervalSince(startTime) / endTime.timeIntervalSince(startTime)
            let progress = min(amount, roundToSupportedBolusVolume(amount * progressPercentage))

            state.reservoirLevel = originalReservoirLevel - progress
            state.bolusProgress = progress

            guard progressPercentage >= 1.0 else {
                pumpManager.notifyStateDidUpdate()
                sendStatusUpdate()
                return
            }

            stopBolusTimer()

            // Records that ran out meanwhile first, then the bolus: written as it completes, so the completion
            // notification already names its record
            pumpManager.advanceDelivery()
            state.finishBolus(delivered: amount, cause: bolusCompleted, at: .now)
            pumpManager.notifyStateDidUpdate()
            sendStatusUpdate(completedBolus: CompletedBolus(cause: bolusCompleted, delivered: amount))
        }
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
