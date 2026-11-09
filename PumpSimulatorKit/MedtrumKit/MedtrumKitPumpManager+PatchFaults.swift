import Foundation

/// The patch faults, as the simulator lets you arm them - see `MedtrumKitPatchFaults`
extension MedtrumKitPumpManager {
    /// Patch faults and events: halts, record reads, status gaps, the stopped patch, running dry
    func patchFaultControls() -> PumpManagerControlGroup {
        let haltCommands = [(command: UInt8?.none, name: "None")] +
            MedtrumKitPatchFaults.haltCommands.map { (command: UInt8?.some($0), name: MedtrumKitCommandFaults.name(of: $0)) }

        let rows = [
            PumpManagerControlRow(
                label: "Halt on a command",
                detail: "The patch halts as it executes the command with success: right after its answer, or with " +
                    "the answer lost. Once.",
                controls: [
                    .picker(
                        "Command",
                        options: haltCommands.map(\.name),
                        get: { [weak self] in
                            let command = self?.patchFaults.current.haltCommand
                            return haltCommands.firstIndex { $0.command == command } ?? 0
                        },
                        set: { [weak self] index in self?.updatePatchFaults { $0.haltCommand = haltCommands[index].command } }
                    ),
                    haltKindPicker(),
                    .toggle(
                        "Answer lost",
                        get: { [weak self] in self?.patchFaults.current.haltLosesAnswer ?? false },
                        set: { [weak self] lost in self?.updatePatchFaults { $0.haltLosesAnswer = lost } }
                    ),
                ]
            ),
            PumpManagerControlRow(
                label: "Halt now",
                detail: "The patch stops delivering on its own. Running dry empties what is left first.",
                controls: [
                    .button("Occlusion") { [weak self] in self?.queue.async { self?.haltNow(.occlusion) } },
                    .button("Run dry") { [weak self] in self?.queue.async { self?.haltNow(.reservoirEmpty) } },
                    .button("Hourly maximum") { [weak self] in self?.queue.async { self?.haltNow(.hourlyMaxSuspended) } },
                ]
            ),
            PumpManagerControlRow(
                label: "Record read",
                detail: "What a GetRecord answers instead of the record. Once, or every read of the record it hits. " +
                    "\"Record number set\": the number under Record history.",
                controls: [
                    .picker(
                        "Which",
                        options: RecordReadTarget.allCases.map(\.title),
                        get: { [weak self] in self?.patchFaults.current.recordTarget.rawValue ?? 0 },
                        set: { [weak self] index in
                            self?.updatePatchFaults { $0.recordTarget = RecordReadTarget(rawValue: index) ?? .any }
                        }
                    ),
                    .picker(
                        "Fault",
                        options: RecordReadFault.allCases.map(\.title),
                        get: { [weak self] in self?.patchFaults.current.recordFault.rawValue ?? 0 },
                        set: { [weak self] index in
                            self?.updatePatchFaults {
                                $0.recordFault = RecordReadFault(rawValue: index) ?? .normal
                                $0.recordFaultNumber = nil
                            }
                        }
                    ),
                    .toggle(
                        "Every read of it",
                        get: { [weak self] in self?.patchFaults.current.recordFaultSticks ?? false },
                        set: { [weak self] sticks in self?.updatePatchFaults { $0.recordFaultSticks = sticks } }
                    ),
                ]
            ),
            PumpManagerControlRow(
                label: "Status gap",
                detail: "No notification goes out - heartbeats, completions, the status a command pushes. " +
                    "Commands are answered, a Synchronize too - unless answers go too: the link is silent.",
                controls: [
                    .number(
                        "Minutes",
                        range: 1 ... 120,
                        get: { [weak self] in self?.patchFaults.current.statusGapMinutes ?? 5 },
                        set: { [weak self] minutes in self?.updatePatchFaults { $0.statusGapMinutes = minutes } }
                    ),
                    .toggle(
                        "Answers too",
                        get: { [weak self] in self?.patchFaults.current.statusGapSilencesLink ?? false },
                        set: { [weak self] silent in self?.updatePatchFaults { $0.statusGapSilencesLink = silent } }
                    ),
                    .button("Start") { [weak self] in self?.startStatusGap() },
                    .button("End") { [weak self] in
                        self?.updatePatchFaults { $0.statusGapUntil = nil }
                        self?.queue.async {
                            self?.bluetooth.endSilence()
                            MedtrumKitPackets.sendStatusUpdate()
                        }
                    },
                ]
            ),
            PumpManagerControlRow(
                label: "After a StopPatch",
                detail: "The old patch goes on answering - stopped (128), its own id and records - before the " +
                    "base is on a new one. 0: at once.",
                controls: [
                    .number(
                        "Seconds",
                        range: 0 ... 600,
                        step: 15,
                        unit: " s",
                        get: { [weak self] in self?.patchFaults.current.stoppedPatchSeconds ?? 0 },
                        set: { [weak self] seconds in self?.updatePatchFaults { $0.stoppedPatchSeconds = seconds } }
                    ),
                ]
            ),
            PumpManagerControlRow(
                label: "Patch replaced",
                detail: "The base is on a new, filled patch - no StopPatch was sent to the old one. The phone's " +
                    "session on the old patch is never ended by the patch. Now, or 5 s into the next bolus.",
                controls: [
                    .button("New patch on the base") { [weak self] in
                        self?.queue.async {
                            self?.logger.warning("[FAULT] The base is on a new patch: the old one was never stopped")
                            self?.putNewPatch(announce: true)
                        }
                    },
                    .toggle(
                        "During the next bolus",
                        get: { [weak self] in self?.patchFaults.current.replaceDuringNextBolus ?? false },
                        set: { [weak self] armed in self?.updatePatchFaults { $0.replaceDuringNextBolus = armed } }
                    ),
                ]
            ),
            PumpManagerControlRow(
                label: "Base reset",
                detail: "The base restarts: delivery stops, nothing more is written for the patch, and the base " +
                    "reports state none with the next patch's id. Then fill a new patch.",
                controls: [
                    .button("Reset the base") { [weak self] in self?.queue.async { self?.baseReset() } },
                ]
            ),
            PumpManagerControlRow(
                label: "Running dry",
                detail: "The next bolus empties the reservoir halfway. A temp basal ended by running dry claims " +
                    "more than rate × time in its record, as real patches' do.",
                controls: [
                    .toggle(
                        "Next bolus runs dry",
                        get: { [weak self] in self?.patchFaults.current.dryDuringNextBolus ?? false },
                        set: { [weak self] armed in self?.updatePatchFaults { $0.dryDuringNextBolus = armed } }
                    ),
                    .toggle(
                        "Record claims more",
                        get: { [weak self] in self?.patchFaults.current.emptyRecordClaimsMore ?? false },
                        set: { [weak self] claims in self?.updatePatchFaults { $0.emptyRecordClaimsMore = claims } }
                    ),
                    .number(
                        "By",
                        range: 0.05 ... 1,
                        step: 0.05,
                        unit: " U",
                        get: { [weak self] in self?.patchFaults.current.emptyRecordExtra ?? 0.1 },
                        set: { [weak self] units in self?.updatePatchFaults { $0.emptyRecordExtra = units } }
                    ),
                ]
            ),
            PumpManagerControlRow(
                label: "Reservoir shortcut",
                detail: "A test shortcut, not something a real patch does: leaves this much in the reservoir now, " +
                    "so delivery runs it dry soon.",
                controls: [
                    .number(
                        "Leave",
                        range: 0.05 ... 50,
                        step: 0.05,
                        unit: " U",
                        get: { [weak self] in self?.patchFaults.current.reservoirShortcut ?? 1 },
                        set: { [weak self] units in self?.updatePatchFaults { $0.reservoirShortcut = units } }
                    ),
                    .button("Apply") { [weak self] in self?.queue.async { self?.applyReservoirShortcut() } },
                ]
            ),
        ]

        return PumpManagerControlGroup(
            title: "Patch faults",
            rows: rows,
            footnote: """
            Back to off at Stop, Reset Pump, Disarm all and as a scenario is armed - a stopped patch still answering \
            then gives way to a new one. Kept for the next time: the halt kind, the record target, the gap length and \
            the amounts. The armed ones are listed under Armed faults.
            """
        )
    }

    private func haltKindPicker() -> PumpManagerControl {
        .picker(
            "Halt",
            options: HaltKind.allCases.map(\.title),
            get: { [weak self] in self?.patchFaults.current.haltKind.rawValue ?? 0 },
            set: { [weak self] index in self?.updatePatchFaults { $0.haltKind = HaltKind(rawValue: index) ?? .occlusion } }
        )
    }

    /// From the UI: the settings change at once (behind a lock), the state that follows them, the save and the UI's
    /// refresh on the queue
    func updatePatchFaults(_ change: (inout PatchFaultSettings) -> Void) {
        patchFaults.update(change)
        queue.async { [self] in
            applyPatchFaultsToState()
            notifyStateDidUpdate()
        }
    }

    /// The state's copy of what it needs of the settings: the claim of a record ended by running dry
    func applyPatchFaultsToState() {
        let settings = patchFaults.current
        state.emptyRecordExtra = settings.emptyRecordClaimsMore ? settings.emptyRecordExtra : 0
    }

    /// Patch faults back to off, the UI following
    func resetPatchFaults() {
        patchFaults.reset()
        MedtrumKitPackets.bolusRun?.callOff()
        applyPatchFaultsToState()
        endLingeringStoppedPatch()
        notifyStateDidUpdate()
    }

    /// A stopped patch still answering gives way to a new one now: the fault that kept it is off
    func endLingeringStoppedPatch() {
        guard state.stoppedPatchUntil != nil else {
            return
        }

        logger.info("The stopped patch no longer answers: the base is on a new patch")
        putNewPatch(announce: true)
    }

    func startStatusGap() {
        let minutes = patchFaults.current.statusGapMinutes
        if patchFaults.current.statusGapSilencesLink {
            queue.async { [self] in bluetooth.silenceLink(for: minutes * 60) }
            return
        }

        let until = Date.now.addingTimeInterval(minutes * 60)
        updatePatchFaults { $0.statusGapUntil = until }
        queue.async { [self] in
            logger.warning("[FAULT] Status gap: no notification until \(Self.timeFormatter.string(from: until))")
        }
        queue.asyncAfter(deadline: .now() + minutes * 60) { [weak self] in
            guard let self, patchFaults.current.statusGapUntil == until else {
                return
            }
            patchFaults.update { $0.statusGapUntil = nil }
            logger.warning("[FAULT] Status gap over: notifications again")
            notifyStateDidUpdate()
        }
    }

    func applyReservoirShortcut() {
        advanceDelivery()
        guard state.isPatchRunning else {
            logger.warning("Reservoir shortcut: the patch is not running (\(state.patchState.title))")
            return
        }

        let leave = patchFaults.current.reservoirShortcut
        let running = (state.isDeliveringBasal ? state.segmentDelivered(until: .now) : 0) + (state.bolusProgress ?? 0)
        state.reservoirLevel = running + leave
        logger.warning("[FAULT] Reservoir shortcut: \(leave)U left")
        state.noteLowReservoir(at: .now)
        notifyStateDidUpdate()
        MedtrumKitPackets.sendStatusUpdate()
    }
}
