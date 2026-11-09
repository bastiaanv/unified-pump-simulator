import Foundation

/// How the patch halts, for a halt armed on a command (`PatchFaultSettings.haltCommand`) or set off from the UI
enum HaltKind: Int, CaseIterable {
    case occlusion
    case reservoirEmpty
    case hourlyMaxSuspended

    var title: String {
        switch self {
        case .occlusion: "Occlusion"
        case .reservoirEmpty: "Reservoir empty"
        case .hourlyMaxSuspended: "Hourly maximum"
        }
    }
}

/// What the next GET_RECORD answer carries instead of the record asked for
enum RecordReadFault: Int, CaseIterable {
    case normal
    /// An empty slot, as for a record not written yet
    case emptySlot
    /// The record, its CRC off by one
    case badCrc
    /// The record, with another patch's id in its header
    case otherPatchId
    /// The record cut short - at most 8 bytes of its payload - no CRC
    case truncated

    var title: String {
        switch self {
        case .normal: "Normal"
        case .emptySlot: "Empty slot"
        case .badCrc: "Bad CRC"
        case .otherPatchId: "Another patch's id"
        case .truncated: "Truncated"
        }
    }
}

/// Which record a record read fault waits for
enum RecordReadTarget: Int, CaseIterable {
    case any
    case bolus
    case basal
    /// The record of the number set (`PatchFaultSettings.recordTargetNumber`)
    case number

    var title: String {
        switch self {
        case .any: "Next record read"
        case .bolus: "Next bolus record read"
        case .basal: "Next basal record read"
        case .number: "Record number set"
        }
    }

    func matches(_ record: MedtrumKitRecord, number: Int) -> Bool {
        switch (self, record.kind) {
        case (.any, _),
             (.basal, .basal),
             (.bolus, .bolus):
            true
        case (.number, _):
            Int(record.number) == number
        default:
            false
        }
    }
}

/// What the patch answers a GET_RECORD for a number its record ring no longer holds
enum RecordRingAnswer: Int, CaseIterable {
    /// The record that took its slot: a newer one, its own number in it
    case staleSlot
    /// An error code (8)
    case error

    var title: String {
        switch self {
        case .staleSlot: "The record now in its slot"
        case .error: "An error (code 8)"
        }
    }
}

/// Patch faults and events beyond a command's answer, as the simulator lets you arm them. Changed from the UI, read on
/// the pump manager's queue: behind a lock. Not saved, back to off at Stop and Reset Pump.
struct PatchFaultSettings {
    /// The patch halts as it executes this command - nil: none. Applies to a command it executes with success.
    var haltCommand: UInt8?
    var haltKind: HaltKind = .occlusion
    /// The command's answer is lost with the halt; otherwise it goes out, the halt right after
    var haltLosesAnswer = false

    var recordFault: RecordReadFault = .normal
    var recordTarget: RecordReadTarget = .any
    /// The fault applies to every read of the record it first hit, not to one read only
    var recordFaultSticks = false
    /// The record a sticking fault hit
    var recordFaultNumber: UInt16?
    /// The record a fault for a record number (`RecordReadTarget.number`) is for
    var recordTargetNumber = 10

    /// The next patch activated holds this many records already, dated before it - a fixture for a driver's history
    var preloadAtActivation = false
    var preloadCount = 300
    /// The patch keeps its newest `ringCapacity` records only: a number older than that is answered with
    /// `ringAnswer`
    var ringEnabled = false
    var ringCapacity = 200
    var ringAnswer: RecordRingAnswer = .staleSlot

    /// How long a status gap lasts, and until when one runs: no notification goes out, answers - a Synchronize's
    /// too - do
    var statusGapMinutes: Double = 5
    var statusGapUntil: Date?
    /// The gap takes answers too: the link is silent (`MedtrumKitBluetoothManager.silenceLink`)
    var statusGapSilencesLink = false

    /// After a StopPatch the old patch answers this long - stopped, with its id and records - before the base is on a
    /// new one. 0: at once, as before.
    var stoppedPatchSeconds: Double = 0

    /// The next bolus runs the reservoir dry halfway through
    var dryDuringNextBolus = false
    /// 5 s into the next bolus the base is on a new patch, the old one never stopped
    var replaceDuringNextBolus = false
    /// A temp basal ended by running dry claims more than it delivered, in its record
    var emptyRecordClaimsMore = false
    var emptyRecordExtra: Double = 0.1

    /// The reservoir shortcut: the units it leaves
    var reservoirShortcut: Double = 1

    /// A bolus that stalls (`BolusStallSettings`), and an occlusion minutes after a bolus completed
    var bolusStall = BolusStallSettings()
    var delayedOcclusion = DelayedOcclusionSettings()
    /// The occlusion one of those set for later, and why: the patch halts then (`MedtrumKitPumpManager.occludeLater`)
    var pendingOcclusionAt: Date?
    var pendingOcclusionReason = ""

    var isStatusGap: Bool {
        statusGapUntil.map { $0 > .now } ?? false
    }
}

final class MedtrumKitPatchFaults {
    private let lock = NSLock()
    private var settings = PatchFaultSettings()
    private var _generation = 0

    var current: PatchFaultSettings {
        lock.withLock { settings }
    }

    /// Goes up at every reset - Disarm all, a scenario armed, Stop, Reset Pump: what a fault scheduled for later (a
    /// late answer, a patch replaced into a bolus) checks, so nothing armed before reaches past it
    var generation: Int {
        lock.withLock { _generation }
    }

    @discardableResult func update<Result>(_ change: (inout PatchFaultSettings) -> Result) -> Result {
        lock.withLock { change(&settings) }
    }

    /// Everything back to off. Kept for the next time: the halt kind, the record target, the gap length, the amounts.
    func reset() {
        lock.withLock {
            _generation += 1
            settings.haltCommand = nil
            settings.haltLosesAnswer = false
            settings.recordFault = .normal
            settings.recordFaultSticks = false
            settings.recordFaultNumber = nil
            settings.statusGapUntil = nil
            settings.statusGapSilencesLink = false
            settings.dryDuringNextBolus = false
            settings.replaceDuringNextBolus = false
            settings.emptyRecordClaimsMore = false
            settings.stoppedPatchSeconds = 0
            settings.bolusStall.scope = .off
            settings.delayedOcclusion.scope = .off
            settings.pendingOcclusionAt = nil
            settings.preloadAtActivation = false
            settings.ringEnabled = false
        }
    }

    /// What a bolus of `amount` starting now takes of the bolus faults: a stall, or an occlusion minutes after it
    /// completes - a stall's own alarm taking the place of that. One for the next bolus only is used up by a bolus it
    /// applies to; a stall that would start past the bolus's end stays armed.
    func takeBolusFaults(for amount: Double) -> (stall: BolusStallPlan?, occlusionMinutes: Double?, notes: [String]) {
        lock.withLock {
            var notes: [String] = []
            var stall: BolusStallPlan?
            if settings.bolusStall.scope != .off {
                stall = settings.bolusStall.plan(for: amount)
                if stall == nil {
                    notes.append(
                        "Bolus stall: this \(amount)U bolus ends before the stall would start" +
                            (settings.bolusStall.scope == .nextBolus ? ", still armed" : "")
                    )
                } else if settings.bolusStall.scope == .nextBolus {
                    settings.bolusStall.scope = .off
                }
            }

            var minutes: Double?
            if settings.delayedOcclusion.scope != .off {
                if stall != nil {
                    notes.append("Delayed occlusion: the stall's own alarm takes its place for this bolus")
                } else {
                    minutes = settings.delayedOcclusion.minutes
                }
                if settings.delayedOcclusion.scope == .nextBolus {
                    settings.delayedOcclusion.scope = .off
                }
            }
            return (stall, minutes, notes)
        }
    }

    /// The commands a halt can be armed on
    static let haltCommands: [UInt8] = [
        CommandType.SET_BOLUS,
        CommandType.CANCEL_BOLUS,
        CommandType.SET_TEMP_BASAL,
        CommandType.CANCEL_TEMP_BASAL,
        CommandType.RESUME_PUMP,
        CommandType.SYNCHRONIZE,
        CommandType.GET_RECORD,
    ]

    /// What is armed, for the list of armed faults
    var armed: [[String]] {
        let settings = current
        var rows: [[String]] = []

        if let command = settings.haltCommand {
            rows.append([
                MedtrumKitCommandFaults.name(of: command),
                "the patch halts (\(settings.haltKind.title)) as it executes it" +
                    (settings.haltLosesAnswer ? ", the answer lost" : ", after the answer"),
            ])
        }
        if settings.recordFault != .normal {
            let target = settings.recordTarget == .number ? "the next read of #\(settings.recordTargetNumber)" :
                settings.recordTarget.title
            let which = settings.recordFaultNumber.map { "every read of #\($0)" } ??
                target + (settings.recordFaultSticks ? ", then every read of it" : "")
            rows.append(["GetRecord", "\(which): \(settings.recordFault.title)"])
        }
        if let until = settings.statusGapUntil, until > .now {
            rows.append(["Statuses", "none sent until \(MedtrumKitPumpManager.timeFormatter.string(from: until))"])
        }
        if settings.preloadAtActivation {
            rows.append(["Activate", "the next patch holds \(settings.preloadCount) records already"])
        }
        if settings.ringEnabled {
            rows.append([
                "GetRecord",
                "the patch keeps its newest \(settings.ringCapacity) records: an older one is answered with " +
                    settings.ringAnswer.title.lowercased(),
            ])
        }
        if settings.stoppedPatchSeconds > 0 {
            rows.append(["StopPatch", "the old patch answers for \(Int(settings.stoppedPatchSeconds)) s after it"])
        }
        if settings.replaceDuringNextBolus {
            rows.append(["SetBolus", "5 s into the next bolus the base is on a new patch, no StopPatch"])
        }
        if settings.dryDuringNextBolus {
            rows.append(["SetBolus", "the reservoir runs dry halfway through the next bolus"])
        }
        if settings.bolusStall.scope != .off {
            rows.append([
                "SetBolus",
                "\(settings.bolusStall.scope == .nextBolus ? "the next bolus" : "every bolus") stalls " +
                    settings.bolusStall.description,
            ])
        }
        if settings.delayedOcclusion.scope != .off {
            rows.append([
                "SetBolus",
                "\(settings.delayedOcclusion.scope == .nextBolus ? "the next bolus" : "every bolus"): " +
                    settings.delayedOcclusion.description,
            ])
        }
        if let at = settings.pendingOcclusionAt {
            rows.append([
                "Patch",
                "occludes at \(MedtrumKitPumpManager.timeFormatter.string(from: at)): \(settings.pendingOcclusionReason)",
            ])
        }
        if settings.emptyRecordClaimsMore {
            rows.append([
                "Records",
                "a temp basal ended by running dry claims \(String(format: "%.2f", settings.emptyRecordExtra)) U more",
            ])
        }
        return rows
    }
}
