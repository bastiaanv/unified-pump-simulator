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

    var title: String {
        switch self {
        case .normal: "Normal"
        case .emptySlot: "Empty slot"
        case .badCrc: "Bad CRC"
        case .otherPatchId: "Another patch's id"
        }
    }
}

/// Which record a record read fault waits for
enum RecordReadTarget: Int, CaseIterable {
    case any
    case bolus
    case basal

    var title: String {
        switch self {
        case .any: "Next record read"
        case .bolus: "Next bolus record read"
        case .basal: "Next basal record read"
        }
    }

    func matches(_ record: MedtrumKitRecord) -> Bool {
        switch (self, record.kind) {
        case (.any, _),
             (.basal, .basal),
             (.bolus, .bolus):
            true
        default:
            false
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
            let which = settings.recordFaultNumber.map { "every read of #\($0)" } ??
                settings.recordTarget.title + (settings.recordFaultSticks ? ", then every read of it" : "")
            rows.append(["GetRecord", "\(which): \(settings.recordFault.title)"])
        }
        if let until = settings.statusGapUntil, until > .now {
            rows.append(["Statuses", "none sent until \(MedtrumKitPumpManager.timeFormatter.string(from: until))"])
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
        if settings.emptyRecordClaimsMore {
            rows.append([
                "Records",
                "a temp basal ended by running dry claims \(String(format: "%.2f", settings.emptyRecordExtra)) U more",
            ])
        }
        return rows
    }
}
