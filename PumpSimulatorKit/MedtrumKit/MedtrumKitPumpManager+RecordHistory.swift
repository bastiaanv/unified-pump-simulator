import Foundation

/// Fixtures for a driver's patch history - a patch with a past, a record ring, a record that can't be read - as the
/// simulator lets you arm them
extension MedtrumKitPumpManager {
    func recordHistoryControls() -> PumpManagerControlGroup {
        let rows = [
            PumpManagerControlRow(
                label: "Preload",
                detail: "The next patch activated holds this many records already - temp basals, the schedule, " +
                    "boluses - dated over the days before it, numbered from 1; its time sync comes after them. " +
                    "Once: back to off as a patch activates.",
                controls: [
                    .number(
                        "Records",
                        range: 50 ... 500,
                        step: 50,
                        get: { [weak self] in Double(self?.patchFaults.current.preloadCount ?? 300) },
                        set: { [weak self] count in self?.updatePatchFaults { $0.preloadCount = Int(count) } }
                    ),
                    .toggle(
                        "At the next activation",
                        get: { [weak self] in self?.patchFaults.current.preloadAtActivation ?? false },
                        set: { [weak self] armed in self?.updatePatchFaults { $0.preloadAtActivation = armed } }
                    ),
                ]
            ),
            PumpManagerControlRow(
                label: "Record ring",
                detail: "The patch keeps its newest records only - how many a real one keeps is not known. A " +
                    "GetRecord for an older number is answered with the record now in its slot (a newer one, its " +
                    "own number in it), or with code 8.",
                controls: [
                    .toggle(
                        "On",
                        get: { [weak self] in self?.patchFaults.current.ringEnabled ?? false },
                        set: { [weak self] on in self?.updatePatchFaults { $0.ringEnabled = on } }
                    ),
                    .number(
                        "Keeps",
                        range: 20 ... 1000,
                        step: 20,
                        get: { [weak self] in Double(self?.patchFaults.current.ringCapacity ?? 200) },
                        set: { [weak self] count in self?.updatePatchFaults { $0.ringCapacity = Int(count) } }
                    ),
                    .picker(
                        "Older ones",
                        options: RecordRingAnswer.allCases.map(\.title),
                        get: { [weak self] in self?.patchFaults.current.ringAnswer.rawValue ?? 0 },
                        set: { [weak self] index in
                            self?.updatePatchFaults { $0.ringAnswer = RecordRingAnswer(rawValue: index) ?? .staleSlot }
                        }
                    ),
                ]
            ),
            PumpManagerControlRow(
                label: "Record unreadable",
                detail: "A GetRecord for this number is answered with the fault picked - truncated: cut to 8 bytes " +
                    "of its payload, no CRC. Once, or every read of it. The same fault as Patch faults → Record read, for one number.",
                controls: [
                    .number(
                        "#",
                        range: 1 ... 1000,
                        get: { [weak self] in Double(self?.patchFaults.current.recordTargetNumber ?? 10) },
                        set: { [weak self] number in
                            self?.updatePatchFaults {
                                $0.recordTargetNumber = Int(number)
                                $0.recordFaultNumber = nil
                            }
                        }
                    ),
                    .picker(
                        "Fault",
                        options: RecordReadFault.allCases.map(\.title),
                        get: { [weak self] in
                            guard let settings = self?.patchFaults.current, settings.recordTarget == .number else {
                                return 0
                            }
                            return settings.recordFault.rawValue
                        },
                        set: { [weak self] index in
                            self?.updatePatchFaults {
                                $0.recordTarget = .number
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
        ]

        return PumpManagerControlGroup(
            title: "Record history",
            rows: rows,
            footnote: """
            MedtrumKit reads only the newest 20 records of a patch it has not synced yet, and from its cursor on \
            after that: a preloaded patch's older numbers are below its cursor, read only by its history screen's \
            fill, kept as "history read". Its sync matches the newest ones to nothing, and imports none. A record \
            answered with another number, an error or truncated is shown as one that could not be read; MedtrumKit \
            does not check a record's CRC, so a bad CRC is read as the record. Back to off at Stop, Reset Pump, \
            Disarm all and as a scenario is armed; the counts and the number are kept.
            """
        )
    }
}
