import Foundation

/// One-click presets: each disarms everything, then arms the faults one test needs. A row says what to do on the phone
/// and what the patch then does; the log repeats it as the scenario is armed. What a driver should make of it is for
/// the driver's own test notes.
extension MedtrumKitPumpManager {
    private struct Scenario {
        let name: String
        let detail: String
        let buttons: [(label: String, arm: (MedtrumKitPumpManager) -> Void)]
    }

    private static let scenarios: [Scenario] = [
        Scenario(
            name: "Activation answer lost",
            detail: "Change the patch. The patch activates, but neither its answer nor the status it pushes is " +
                "sent. Its later statuses show it active, with its new id. A second Activate is refused (code 8).",
            buttons: [("Arm", { $0.armCommand(CommandType.ACTIVATE, .executedNoAnswer) })]
        ),
        Scenario(
            name: "Session never ended",
            detail: "Bolus 1 U or more. 5 s into it, the base is on a new, filled patch. No StopPatch reached the " +
                "old patch, and the bolus's record is never written.",
            buttons: [("Arm", { pumpManager in pumpManager.patchFaults.update { $0.replaceDuringNextBolus = true } })]
        ),
        Scenario(
            name: "Forced deactivation",
            detail: "Deactivate. No StopPatch reaches the patch, so it goes on delivering and reporting under its " +
                "own id until New patch puts the base on a new one. \"Stop runs, answer lost\": the patch stops, its " +
                "answer is lost, it answers as stopped (128) for 2 min, then the base is on a new patch.",
            buttons: [
                ("Arm", { $0.armCommand(CommandType.STOP_PATCH, .notExecuted, once: false) }),
                ("Stop runs, answer lost", { pumpManager in
                    pumpManager.armCommand(CommandType.STOP_PATCH, .executedNoAnswer)
                    pumpManager.patchFaults.update { $0.stoppedPatchSeconds = 120 }
                }),
            ]
        ),
        Scenario(
            name: "Resume after a suspend",
            detail: "Suspend in the app, resume a minute later. The suspend writes the segment's record and an " +
                "ALARM record (bit 4), the resume a RESUMED record. Nothing needs arming for that; the button loses " +
                "the resume's answer and the status it pushes - the patch resumes all the same.",
            buttons: [("Resume answer lost", { $0.armCommand(CommandType.RESUME_PUMP, .executedNoAnswer) })]
        ),
        Scenario(
            name: "Two cancels unanswered",
            detail: "Needs a temp basal running. The next CancelTempBasal never reaches the patch: the temp basal " +
                "goes on, and statuses show it. The one after that runs and ends it, its answer lost; statuses then " +
                "show the schedule, and its record is there. Any cancel uses them up, the loop's too.",
            buttons: [("Arm", { pumpManager in
                pumpManager.commandFaults.queue(
                    [CommandFault(mode: .notExecuted), CommandFault(mode: .executedNoAnswer)],
                    for: CommandType.CANCEL_TEMP_BASAL
                )
            })]
        ),
        Scenario(
            name: "Dry-out, temp basal and bolus",
            detail: "Needs a temp basal running. Bolus 0.5 U or more: the reservoir holds half of it. The patch " +
                "writes ALARM bit 2 (low reservoir, unless written already), then as it runs dry the bolus cut short, " +
                "the temp basal (STOP_EMPTY), DAILY and ALARM bit 8. It halts in state 98: the notification has a " +
                "1-byte basal field and the bolus's completion, the full statuses after it no basal field.",
            buttons: [("Arm", { pumpManager in pumpManager.patchFaults.update { $0.dryDuringNextBolus = true } })]
        ),
        Scenario(
            name: "Empty record claims more",
            detail: "Needs a temp basal running, 0.5 U/h or more. 0.15 U is left now: the patch runs dry within " +
                "minutes, and the temp basal's STOP_EMPTY record claims 0.10 U more than rate × time.",
            buttons: [("Arm", { pumpManager in
                pumpManager.patchFaults.update {
                    $0.emptyRecordClaimsMore = true
                    $0.emptyRecordExtra = 0.1
                    $0.reservoirShortcut = 0.15
                }
                pumpManager.queue.async { pumpManager.applyReservoirShortcut() }
            })]
        ),
        Scenario(
            name: "Halt as a temp basal is set",
            detail: "The next SetTempBasal is answered, then the patch occludes at once: the new temp basal's " +
                "record is seconds long, the occlusion's status follows the answer.",
            buttons: [("Arm", { pumpManager in
                pumpManager.patchFaults.update {
                    $0.haltCommand = CommandType.SET_TEMP_BASAL
                    $0.haltKind = .occlusion
                    $0.haltLosesAnswer = false
                }
            })]
        ),
        Scenario(
            name: "Halt as a bolus starts",
            detail: "Bolus. The patch starts it and occludes after its first 0.05 U; the SetBolus answer is lost. " +
                "Records: the bolus (0.05 U, under the number the answer would have named), the segment " +
                "(STOP_OCCLUSION), DAILY, ALARM bit 6.",
            buttons: [("Arm", { pumpManager in
                pumpManager.patchFaults.update {
                    $0.haltCommand = CommandType.SET_BOLUS
                    $0.haltKind = .occlusion
                    $0.haltLosesAnswer = true
                }
            })]
        ),
        Scenario(
            name: "Base reset",
            detail: "The base restarts now: delivery stops, nothing more is written, and the base reports state " +
                "none with the next patch's id and its age. Fill a new patch to go on.",
            buttons: [("Reset the base", { pumpManager in pumpManager.queue.async { pumpManager.baseReset() } })]
        ),
        Scenario(
            name: "Old patch answers after its stop",
            detail: "Deactivate. The stopped patch goes on answering for 2 min - state 128, its own id and records, " +
                "the alarms it had plus bit 14 - and refuses priming. Then the base is on a new patch.",
            buttons: [("Arm", { pumpManager in pumpManager.patchFaults.update { $0.stoppedPatchSeconds = 120 } })]
        ),
        Scenario(
            name: "Status gap",
            detail: "No notification for 10 min - heartbeats, a bolus's completion. Commands are answered, a " +
                "Synchronize too.",
            buttons: [("Start", { pumpManager in
                pumpManager.patchFaults.update {
                    $0.statusGapMinutes = 10
                    $0.statusGapSilencesLink = false
                }
                pumpManager.startStatusGap()
            })]
        ),
        Scenario(
            name: "Link silent",
            detail: "Nothing in or out for 5 min; the phone stays connected. The patch goes on delivering.",
            buttons: [("Start", { pumpManager in
                pumpManager.patchFaults.update {
                    $0.statusGapMinutes = 5
                    $0.statusGapSilencesLink = true
                }
                pumpManager.startStatusGap()
            })]
        ),
        Scenario(
            name: "Bolus record unreadable",
            detail: "Every read of the next bolus record is answered with an empty slot, as for a record not " +
                "written yet.",
            buttons: [("Arm", { pumpManager in
                pumpManager.patchFaults.update {
                    $0.recordTarget = .bolus
                    $0.recordFault = .emptySlot
                    $0.recordFaultSticks = true
                    $0.recordFaultNumber = nil
                }
            })]
        ),
        Scenario(
            name: "Bolus stall as on 2026-10-13",
            detail: "Bolus 5 U. The patch's pace up to 3.5 U, then a 0.1 U step every 40 s, 2 s less each, its other " +
                "packets every 8 s in between. It completes in full after about 8 min, and the patch occludes 205 s " +
                "later. The next bolus only.",
            buttons: [("Arm", { pumpManager in
                pumpManager.armStall {
                    $0.start = .units
                    $0.startUnits = 3.5
                    $0.interval = 40
                    $0.shrink = 2
                    $0.alarm = .afterCompletion
                    $0.alarmDelay = 205
                }
            })]
        ),
        Scenario(
            name: "Bolus stall, no alarm",
            detail: "Bolus 2 U or more. From 70% of it, a 0.1 U step every 40 s to its completion in full; the patch " +
                "never occludes. Between the steps a notification without the bolus field every 8 s - \"Steps " +
                "only\": nothing at all, not even the heartbeat. The next bolus only.",
            buttons: [
                ("Arm", { pumpManager in pumpManager.armStall { _ in } }),
                ("Steps only", { pumpManager in pumpManager.armStall { $0.stepsOnly = true } }),
            ]
        ),
        Scenario(
            name: "Bolus stall that ends",
            detail: "Bolus 2 U or more. From 70% of it, a 0.1 U step every 40 s, the other packets every 8 s. " +
                "\"Resumes\": the patch's pace again after 3 slow steps, on to a normal completion. \"Occludes\": " +
                "the patch occludes after 3 slow steps, the bolus cut there (cause 9). The next bolus only.",
            buttons: [
                ("Resumes", { pumpManager in pumpManager.armStall { $0.resumeAfter = 3 } }),
                ("Occludes", { pumpManager in
                    pumpManager.armStall {
                        $0.alarm = .duringStall
                        $0.alarmAfterSlowSteps = 3
                    }
                }),
            ]
        ),
        Scenario(
            name: "Delayed occlusion",
            detail: "Bolus. It runs and completes in full at the patch's pace; 3 min after its completion the patch " +
                "occludes (state 96, alarm bit 6): the segment's record (STOP_OCCLUSION), DAILY, ALARM bit 6.",
            buttons: [("Arm", { pumpManager in
                pumpManager.patchFaults.update {
                    $0.delayedOcclusion.scope = .nextBolus
                    $0.delayedOcclusion.minutes = 3
                }
            })]
        ),
    ]

    func scenarioControls() -> PumpManagerControlGroup {
        let disarm = PumpManagerControlRow(
            label: "Disarm all",
            detail: "Every command and patch fault back to off, a silent link speaking again, a stopped patch still " +
                "answering giving way to a new one. Arming a scenario does this first.",
            controls: [.button("Disarm") { [weak self] in self?.disarmAll(log: true) }]
        )

        let newPatch = PumpManagerControlRow(
            label: "New patch",
            detail: "The base is on a new, filled patch - the old one never stopped. A StopPatch fault is cleared.",
            controls: [.button("New patch on the base") { [weak self] in self?.putNewPatchWithoutStop() }]
        )

        let rows = Self.scenarios.map { scenario in
            PumpManagerControlRow(
                label: scenario.name,
                detail: scenario.detail,
                controls: scenario.buttons.map { button in
                    .button(button.label) { [weak self] in self?.arm(scenario, button.label, button.arm) }
                }
            )
        }

        return PumpManagerControlGroup(
            title: "Scenarios",
            rows: [disarm, newPatch] + rows,
            footnote: """
            Start the simulator and connect the phone first. What is armed is listed under Armed faults; a fault for \
            one command is used up by it. The log marks the simulator's side with [FAULT] and [SCENARIO].
            """
        )
    }

    private func arm(_ scenario: Scenario, _ variant: String, _ configure: @escaping (MedtrumKitPumpManager) -> Void) {
        disarmAll(log: false)
        configure(self)
        queue.async { [self] in
            applyPatchFaultsToState()
            let title = scenario.buttons.count > 1 ? "\(scenario.name) (\(variant))" : scenario.name
            logger.warning("[SCENARIO] \(title): \(scenario.detail)")
            notifyStateDidUpdate()
        }
    }

    /// Every fault back to off - the settings at once, what they hold (a silent link, a stopped patch still answering),
    /// the save and the UI's refresh on the queue
    private func disarmAll(log: Bool) {
        commandFaults.reset()
        patchFaults.reset()
        queue.async { [self] in
            bluetooth.endSilence()
            MedtrumKitPackets.bolusRun?.callOff()
            applyPatchFaultsToState()
            endLingeringStoppedPatch()
            if log {
                logger.info("[SCENARIO] Everything disarmed")
            }
            notifyStateDidUpdate()
        }
    }

    /// The old patch is gone without a StopPatch, the base on a new one: the new one is stopped as usual
    private func putNewPatchWithoutStop() {
        commandFaults.update(CommandType.STOP_PATCH) { $0.mode = .normal }
        queue.async { [self] in
            logger.warning("[SCENARIO] The base is on a new patch: the old one was never stopped")
            putNewPatch(announce: true)
        }
    }

    /// A stall for the next bolus: the variants' defaults - from 70% of it, a step every 40 s, other packets every 8 s,
    /// no resume, no alarm - changed by `configure`
    private func armStall(_ configure: (inout BolusStallSettings) -> Void) {
        patchFaults.update { settings in
            var stall = settings.bolusStall
            stall.scope = .nextBolus
            stall.start = .fraction
            stall.startPercent = 70
            stall.interval = 40
            stall.shrink = 0
            stall.stepsOnly = false
            stall.resumeAfter = 0
            stall.alarm = .none
            configure(&stall)
            settings.bolusStall = stall
        }
    }

    /// `mode` for the next `command` - or, not `once`, every one until changed
    private func armCommand(_ command: UInt8, _ mode: CommandFaultMode, once: Bool = true) {
        commandFaults.update(command) {
            $0.mode = mode
            $0.once = once
        }
    }
}
