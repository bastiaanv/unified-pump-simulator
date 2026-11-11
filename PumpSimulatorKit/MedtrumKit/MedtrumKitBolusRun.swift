import Foundation

/// The running bolus, step by step, on the pump manager's queue: a 0.05 U step every 2 s (`bolusStepInterval`), each
/// one told in a notification, the completion in the last. A stall armed for it (`BolusStallPlan`) slows it past an
/// amount to a 0.1 U step every so many seconds - the patch's other packets every 8 s in between, or nothing at all -
/// back to the patch's pace after some slow steps if it resumes, its occlusion alarm during the stall, after the
/// completion, or never.
///
/// It ends as the bolus does - completed here, or ended by a cancel, a halt, a suspend or a new patch, which stop it
/// (`MedtrumKitPackets.stopBolusTimer`).
final class BolusRun {
    let amount: Double
    let startTime: Date
    let stall: BolusStallPlan?
    /// An occlusion this many minutes after a completion in full (`DelayedOcclusionSettings`)
    let occlusionMinutes: Double?
    private weak var pumpManager: MedtrumKitPumpManager?

    private var timer: DispatchSourceTimer?
    /// The other packets during the stall: a notification without the bolus field
    private var otherPackets: DispatchSourceTimer?
    /// Past the stall's start, and not resumed
    private(set) var isStalled = false
    private var resumed = false
    /// The faults were disarmed as it ran: on at the patch's pace, no occlusion after it
    private var calledOff = false
    private var slowSteps = 0
    /// The gap to the next slow step
    private var slowInterval: TimeInterval = 0
    private var lastStepAt = Date.now

    init(
        amount: Double,
        startTime: Date,
        stall: BolusStallPlan?,
        occlusionMinutes: Double?,
        pumpManager: MedtrumKitPumpManager
    ) {
        self.amount = amount
        self.startTime = startTime
        self.stall = stall
        self.occlusionMinutes = occlusionMinutes
        self.pumpManager = pumpManager
        slowInterval = stall?.interval ?? 0
    }

    /// Stalled with nothing in between the steps: the heartbeat is held too
    var holdsHeartbeats: Bool {
        isStalled && stall?.stepsOnly == true
    }

    /// What it does beyond the patch's pace, for the list of armed faults - nil if nothing
    var faultDescription: String? {
        if calledOff {
            return nil
        }
        if let stall {
            if isStalled {
                return "stalled past \(String(format: "%.2f", stall.fromUnits))U: \(slowSteps) slow step(s) so far"
            }
            return resumed ? "back to the patch's pace after \(slowSteps) slow steps" :
                "stalls past \(String(format: "%.2f", stall.fromUnits))U"
        }
        return occlusionMinutes.map { "occludes \(String(format: "%g", $0)) min after it completes in full" }
    }

    private static var logger: PumpManagerLogger {
        MedtrumKitPackets.logger
    }

    func start() {
        guard let pumpManager else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: pumpManager.queue)
        timer.setEventHandler { [weak self] in self?.step() }
        self.timer = timer
        lastStepAt = .now
        // The first pulse went with the answer: a stall from there starts at once
        enterStallIfDue(progress: pumpManager.state.bolusProgress ?? 0)
        timer.schedule(deadline: .now() + nextDelay())
        timer.resume()
    }

    /// Disarm all, Stop, Reset Pump: a stall or an occlusion armed for this bolus is called off, it goes on at the
    /// patch's pace
    func callOff() {
        guard stall != nil || occlusionMinutes != nil, !calledOff else {
            return
        }

        calledOff = true
        resumed = true
        if isStalled {
            isStalled = false
            stopOtherPackets()
            timer?.schedule(deadline: .now() + MedtrumKitPackets.bolusStepInterval)
        }
        Self.logger.warning("[FAULT] Bolus faults disarmed: the running bolus goes on at the patch's pace")
    }

    /// This run is over: its timers stop, and it is no longer the bolus's run - unless a newer one took its place, which
    /// a stale handler of this one leaves alone
    private func stop() {
        cancel()
        if MedtrumKitPackets.bolusRun === self {
            MedtrumKitPackets.bolusRun = nil
        }
    }

    func cancel() {
        timer?.cancel()
        timer = nil
        stopOtherPackets()
    }

    private func step() {
        guard let pumpManager else {
            cancel()
            return
        }

        let state = pumpManager.state
        // Ended meanwhile - cancelled, cut short - or another patch
        guard state.isBolusRunning, state.bolusStart == startTime else {
            stop()
            return
        }

        let previous = state.bolusProgress ?? 0
        let slow = isStalled
        let increment = slow ? BolusStallSettings.slowStepUnits : MedtrumKitPackets.bolusStepUnits
        let progress = min(amount, MedtrumKitState.roundToSteps(previous + increment))

        // What the reservoir holds for the bolus: short of it, the patch runs dry with the bolus cut at that. One that
        // empties it exactly completes, the basal then runs dry (`MedtrumKitState.advance`).
        let available = state.insulinForBolus(at: .now)
        if available < amount, progress >= available {
            state.bolusProgress = available
            stop()
            pumpManager.runDry()
            return
        }

        state.bolusProgress = progress
        state.noteLowReservoir(at: .now)

        let gap = Date.now.timeIntervalSince(lastStepAt)
        lastStepAt = .now
        if slow {
            slowSteps += 1
            Self.logger.warning(
                "[FAULT] Bolus stall: slow step \(slowSteps), \(String(format: "%.2f", progress))U of \(amount)U, " +
                    "\(Int(gap.rounded())) s after the last"
            )
        }

        guard progress < amount - 1E-9 else {
            complete()
            return
        }

        pumpManager.notifyStateDidUpdate()
        MedtrumKitPackets.sendStatusUpdate()

        if slow, let stall {
            if stall.alarm == .duringStall, slowSteps >= stall.alarmAfterSlowSteps {
                Self.logger.warning("[FAULT] Bolus stall: the patch raises its occlusion after \(slowSteps) slow steps")
                cancel()
                pumpManager.haltNow(.occlusion)
                return
            }
            if let resumeAfter = stall.resumeAfter, slowSteps >= resumeAfter {
                resumed = true
                isStalled = false
                stopOtherPackets()
                Self.logger.warning("[FAULT] Bolus stall over after \(slowSteps) slow steps: the patch's pace again")
            }
        }

        enterStallIfDue(progress: progress)
        timer?.schedule(deadline: .now() + nextDelay())
    }

    /// The stall starts once the bolus has delivered what it starts at
    private func enterStallIfDue(progress: Double) {
        guard let stall, !isStalled, !resumed, progress >= stall.fromUnits - 1E-9 else {
            return
        }

        isStalled = true
        Self.logger.warning(
            "[FAULT] Bolus stall from \(String(format: "%.2f", progress))U of \(amount)U: a 0.1 U step every " +
                "\(Int(slowInterval)) s" + (stall.shrink > 0 ? ", \(Int(stall.shrink)) s less each" : "") +
                (stall.stepsOnly ? ", nothing sent in between - no heartbeat either" :
                    ", other packets every \(Int(BolusStallSettings.otherPacketsEvery)) s")
        )
        guard !stall.stepsOnly, let pumpManager else {
            return
        }

        otherPackets = MedtrumKitPackets.repeatingTimer(on: pumpManager.queue, every: BolusStallSettings.otherPacketsEvery) {
            [weak self] in
            guard let self, isStalled, let pumpManager = self.pumpManager, pumpManager.state.bolusStart == startTime else {
                return
            }
            MedtrumKitPackets.sendStatusUpdate(withoutBolusField: true)
        }
    }

    /// The gap to the next step: the patch's pace, or the stall's - each slow one shorter by `shrink`
    private func nextDelay() -> TimeInterval {
        guard isStalled, let stall else {
            return MedtrumKitPackets.bolusStepInterval
        }

        let delay = slowInterval
        slowInterval = max(BolusStallSettings.minimumInterval, slowInterval - stall.shrink)
        return delay
    }

    private func stopOtherPackets() {
        otherPackets?.cancel()
        otherPackets = nil
    }

    /// Delivered in full: the record, the completion notification, and an occlusion later if one is armed for it
    private func complete() {
        guard let pumpManager else {
            return
        }

        stop()
        let state = pumpManager.state

        // Records that ran out meanwhile first, then the bolus: written as it completes, so the completion notification
        // already names its record. Those may have ended it - the basal ran dry first.
        pumpManager.advanceDelivery()
        guard state.isBolusRunning, state.bolusStart == startTime else {
            return
        }
        state.finishBolus(delivered: amount, cause: MedtrumKitPackets.bolusCompleted, at: .now)
        pumpManager.notifyStateDidUpdate()
        MedtrumKitPackets.sendStatusUpdate(
            completedBolus: MedtrumKitPackets.CompletedBolus(cause: MedtrumKitPackets.bolusCompleted, delivered: amount)
        )

        if calledOff {
            return
        }
        if let stall {
            Self.logger.warning(
                "[FAULT] The stalled bolus completed in full, \(amount)U in " +
                    "\(Int(Date.now.timeIntervalSince(startTime))) s, \(slowSteps) slow steps" +
                    (resumed ? ", the patch's pace again before the end" : "")
            )
            if stall.alarm == .afterCompletion {
                pumpManager.occludeLater(after: stall.alarmDelay, "\(Int(stall.alarmDelay)) s after the stalled bolus completed")
            }
            // Set to occlude during the stall, it completed within the slow steps first: the patch occludes now, at
            // its completion
            if stall.alarm == .duringStall, !resumed {
                Self.logger.warning(
                    "[FAULT] Bolus stall: the bolus completed within \(slowSteps) of the \(stall.alarmAfterSlowSteps) slow " +
                        "steps set: the patch occludes at its completion"
                )
                pumpManager.haltNow(.occlusion)
            }
        } else if let occlusionMinutes {
            pumpManager.occludeLater(
                after: occlusionMinutes * 60,
                "\(String(format: "%g", occlusionMinutes)) min after the bolus completed"
            )
        }
    }
}
