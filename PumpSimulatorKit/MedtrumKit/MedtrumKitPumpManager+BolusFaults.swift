import Foundation

/// The bolus faults, as the simulator lets you arm them - a bolus that stalls, an occlusion after a bolus - see
/// `BolusStallSettings` and `BolusRun`
extension MedtrumKitPumpManager {
    func bolusFaultControls() -> PumpManagerControlGroup {
        let rows = [
            PumpManagerControlRow(
                label: "Bolus stall",
                detail: "The bolus goes at the patch's pace (0.05 U every 2 s), then from the start set one 0.1 U " +
                    "step every so many seconds - each the seconds set shorter than the last, down to 4 s - and " +
                    "completes in full. Next bolus only (back to off as a bolus takes it), or every bolus. A stall " +
                    "set to start past a bolus's end leaves that bolus alone.",
                controls: [
                    scopePicker(\.bolusStall.scope),
                    .picker(
                        "Start",
                        options: BolusStallStart.allCases.map(\.title),
                        get: { [weak self] in self?.patchFaults.current.bolusStall.start.rawValue ?? 0 },
                        set: { [weak self] index in
                            self?.updatePatchFaults { $0.bolusStall.start = BolusStallStart(rawValue: index) ?? .fraction }
                        }
                    ),
                    .number(
                        "From",
                        range: 0.05 ... 30,
                        step: 0.05,
                        unit: " U",
                        get: { [weak self] in self?.patchFaults.current.bolusStall.startUnits ?? 3.5 },
                        set: { [weak self] units in self?.updatePatchFaults { $0.bolusStall.startUnits = units } }
                    ),
                    .number(
                        "From",
                        range: 0 ... 95,
                        step: 5,
                        unit: "%",
                        get: { [weak self] in self?.patchFaults.current.bolusStall.startPercent ?? 70 },
                        set: { [weak self] percent in self?.updatePatchFaults { $0.bolusStall.startPercent = percent } }
                    ),
                ]
            ),
            PumpManagerControlRow(
                label: "Stall pace",
                detail: "The gap to the first slow step, how much shorter each next one is (2026-10-13: 40 s, 2 s " +
                    "less each). Between the steps a notification without the bolus field every 8 s - or, steps " +
                    "only, nothing at all, the 30 s heartbeat held too. MedtrumKit takes a silence over 60 s for the " +
                    "link's: steps only, keep the gap under it.",
                controls: [
                    .number(
                        "Every",
                        range: 4 ... 120,
                        unit: " s",
                        get: { [weak self] in self?.patchFaults.current.bolusStall.interval ?? 40 },
                        set: { [weak self] seconds in self?.updatePatchFaults { $0.bolusStall.interval = seconds } }
                    ),
                    .number(
                        "Less each",
                        range: 0 ... 10,
                        unit: " s",
                        get: { [weak self] in self?.patchFaults.current.bolusStall.shrink ?? 0 },
                        set: { [weak self] seconds in self?.updatePatchFaults { $0.bolusStall.shrink = seconds } }
                    ),
                    .toggle(
                        "Steps only",
                        get: { [weak self] in self?.patchFaults.current.bolusStall.stepsOnly ?? false },
                        set: { [weak self] only in self?.updatePatchFaults { $0.bolusStall.stepsOnly = only } }
                    ),
                ]
            ),
            PumpManagerControlRow(
                label: "Stall end",
                detail: "Resume: back to the patch's pace after this many slow steps (0: never), on to a normal " +
                    "completion. The occlusion alarm: seconds after the completion (2026-10-13: 205 s), after a " +
                    "number of slow steps - the bolus cut there - or none.",
                controls: [
                    .number(
                        "Resume after",
                        range: 0 ... 50,
                        unit: " steps",
                        get: { [weak self] in Double(self?.patchFaults.current.bolusStall.resumeAfter ?? 0) },
                        set: { [weak self] steps in self?.updatePatchFaults { $0.bolusStall.resumeAfter = Int(steps) } }
                    ),
                    .picker(
                        "Alarm",
                        options: BolusStallAlarm.allCases.map(\.title),
                        get: { [weak self] in self?.patchFaults.current.bolusStall.alarm.rawValue ?? 0 },
                        set: { [weak self] index in
                            self?.updatePatchFaults { $0.bolusStall.alarm = BolusStallAlarm(rawValue: index) ?? .none }
                        }
                    ),
                    .number(
                        "After",
                        range: 0 ... 900,
                        step: 5,
                        unit: " s",
                        get: { [weak self] in self?.patchFaults.current.bolusStall.alarmDelay ?? 205 },
                        set: { [weak self] seconds in self?.updatePatchFaults { $0.bolusStall.alarmDelay = seconds } }
                    ),
                    .number(
                        "During, after",
                        range: 1 ... 50,
                        unit: " steps",
                        get: { [weak self] in Double(self?.patchFaults.current.bolusStall.alarmAfterSlowSteps ?? 3) },
                        set: { [weak self] steps in
                            self?.updatePatchFaults { $0.bolusStall.alarmAfterSlowSteps = Int(steps) }
                        }
                    ),
                ]
            ),
            PumpManagerControlRow(
                label: "Delayed occlusion",
                detail: "The patch raises its occlusion alarm this many minutes after a bolus completed in full, at " +
                    "its normal pace. Not for a bolus cancelled or cut short; a stall's own alarm takes its place.",
                controls: [
                    scopePicker(\.delayedOcclusion.scope),
                    .number(
                        "After",
                        range: 0.5 ... 60,
                        step: 0.5,
                        unit: " min",
                        get: { [weak self] in self?.patchFaults.current.delayedOcclusion.minutes ?? 3 },
                        set: { [weak self] minutes in self?.updatePatchFaults { $0.delayedOcclusion.minutes = minutes } }
                    ),
                ]
            ),
            PumpManagerControlRow(
                label: "Occlusion to come",
                detail: "One of the above set for later, listed under Armed faults: called off here, or at Disarm " +
                    "all, Stop and Reset Pump.",
                controls: [
                    .button("Call off") { [weak self] in self?.updatePatchFaults { $0.pendingOcclusionAt = nil } },
                ]
            ),
        ]

        return PumpManagerControlGroup(
            title: "Bolus faults",
            rows: rows,
            footnote: """
            A bolus takes what is armed as the patch answers its SetBolus; the log marks the stall's steps with \
            [FAULT]. Back to off at Stop, Reset Pump, Disarm all and as a scenario is armed - the settings are kept \
            for the next time.
            """
        )
    }

    private func scopePicker(_ scope: WritableKeyPath<PatchFaultSettings, BolusFaultScope>) -> PumpManagerControl {
        .picker(
            "For",
            options: BolusFaultScope.allCases.map(\.title),
            get: { [weak self] in self?.patchFaults.current[keyPath: scope].rawValue ?? 0 },
            set: { [weak self] index in
                self?.updatePatchFaults { $0[keyPath: scope] = BolusFaultScope(rawValue: index) ?? .off }
            }
        )
    }

    /// The patch occludes `seconds` from now - unless called off meanwhile (a disarm, another one set) or the patch is
    /// not running then. On the queue.
    func occludeLater(after seconds: TimeInterval, _ reason: String) {
        let at = Date.now.addingTimeInterval(seconds)
        // For this patch only: another one activated meanwhile is not occluded
        let patchId = state.patchId
        let activatedAt = state.activatedAt
        patchFaults.update {
            $0.pendingOcclusionAt = at
            $0.pendingOcclusionReason = reason
        }
        logger.warning("[FAULT] The patch occludes at \(Self.timeFormatter.string(from: at)): \(reason)")
        notifyStateDidUpdate()

        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else {
                return
            }
            let due = patchFaults.update { settings -> Bool in
                guard settings.pendingOcclusionAt == at else {
                    return false
                }
                settings.pendingOcclusionAt = nil
                return true
            }
            guard due else {
                return
            }
            guard state.patchId == patchId, state.activatedAt == activatedAt else {
                logger.warning("[FAULT] The occlusion set for patch \(patchId) is called off: the base is on another patch")
                notifyStateDidUpdate()
                return
            }

            logger.warning("[FAULT] The patch raises its occlusion alarm: \(reason)")
            haltNow(.occlusion)
            notifyStateDidUpdate()
        }
    }

    /// The patch is replaced - stopped, a new one on the base or activated, the base restarted: an occlusion still to
    /// come was for the old one, and is called off
    func callOffPendingOcclusion(_ why: String) {
        let pending = patchFaults.update { settings -> Date? in
            defer { settings.pendingOcclusionAt = nil }
            return settings.pendingOcclusionAt
        }
        if let pending {
            logger.warning(
                "[FAULT] The occlusion set for \(Self.timeFormatter.string(from: pending)) is called off: \(why)"
            )
        }
    }
}
