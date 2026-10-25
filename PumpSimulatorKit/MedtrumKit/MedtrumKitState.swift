import Foundation

class MedtrumKitState {
    init(rawValue: StateRawValue) {
        currentModelIndex = rawValue["currentModelIndex"] as? Int ?? 0
        activatedAt = rawValue["activatedAt"] as? Date
        reservoirLevel = rawValue["reservoirLevel"] as? Double ?? 0
        suspendedSince = rawValue["suspendedSince"] as? Date
        basalSince = rawValue["basalSince"] as? Date ?? Date.now
        suspendedDuration = rawValue["suspendedDuration"] as? TimeInterval
        tempBasalRate = rawValue["tempBasalRate"] as? Double
        tempBasalStart = rawValue["tempBasalStart"] as? Date
        tempBasalDuration = rawValue["tempBasalDuration"] as? TimeInterval
        bolusProgress = rawValue["bolusProgress"] as? Double
        bolusTotal = rawValue["bolusTotal"] as? Double
        primeProgress = rawValue["primeProgress"] as? UInt8
        expirationTimer = rawValue["expirationTimer"] as? UInt8 ?? 1
        hourlyMaxInsulin = rawValue["hourlyMaxInsulin"] as? UInt16 ?? 20
        dailyMaxInsulin = rawValue["dailyMaxInsulin"] as? UInt16 ?? 180
        patchId = rawValue["patchId"] as? UInt32 ?? 192
        basalSequence = rawValue["basalSequence"] as? UInt16 ?? 0
        bolusAnsweredNumber = rawValue["bolusAnsweredNumber"] as? UInt16 ?? rawValue["bolusRecordNumber"] as? UInt16
        bolusStart = rawValue["bolusStart"] as? Date
        lastBolusDelivered = rawValue["lastBolusDelivered"] as? Double ?? 0
        lastBolusCause = rawValue["lastBolusCause"] as? UInt8 ?? 0
        dayStart = rawValue["dayStart"] as? Date
        dayBolus = rawValue["dayBolus"] as? Double ?? 0
        dayBasal = rawValue["dayBasal"] as? Double ?? 0
        timeZoneOffset = rawValue["timeZoneOffset"] as? Int

        if let rawRecordLog = rawValue["recordLog"] as? Data,
           let decoded = try? JSONDecoder().decode(MedtrumKitRecordLog.self, from: rawRecordLog)
        {
            _recordLog = decoded
        } else {
            _recordLog = MedtrumKitRecordLog()
        }

        if let rawBasal = rawValue["basal"] as? Data {
            do {
                basal = try JSONDecoder().decode([BasalItem].self, from: rawBasal)
            } catch {
                basal = []
            }
        } else {
            basal = []
        }

        if let rawAlarmSettings = rawValue["alarmSettings"] as? AlarmSettings.RawValue {
            alarmSettings = AlarmSettings(rawValue: rawAlarmSettings) ?? .None
        } else {
            alarmSettings = .None
        }

        if let rawPatchState = rawValue["patchState"] as? PatchState.RawValue {
            patchState = PatchState(rawValue: rawPatchState) ?? .none
        } else {
            patchState = .none
        }
    }

    func getRaw() -> StateRawValue {
        var state: StateRawValue = [:]
        state["currentModelIndex"] = currentModelIndex
        state["patchState"] = patchState.rawValue
        state["activatedAt"] = activatedAt
        state["reservoirLevel"] = reservoirLevel
        state["basalSince"] = basalSince
        state["suspendedSince"] = suspendedSince
        state["suspendedDuration"] = suspendedDuration
        state["tempBasalRate"] = tempBasalRate
        state["tempBasalStart"] = tempBasalStart
        state["tempBasalDuration"] = tempBasalDuration
        state["bolusProgress"] = bolusProgress
        state["bolusTotal"] = bolusTotal
        state["primeProgress"] = primeProgress
        state["expirationTimer"] = expirationTimer
        state["alarmSettings"] = alarmSettings.rawValue
        state["hourlyMaxInsulin"] = hourlyMaxInsulin
        state["dailyMaxInsulin"] = dailyMaxInsulin
        state["patchId"] = patchId
        state["basalSequence"] = basalSequence
        state["bolusAnsweredNumber"] = bolusAnsweredNumber
        state["bolusStart"] = bolusStart
        state["lastBolusDelivered"] = lastBolusDelivered
        state["lastBolusCause"] = lastBolusCause
        state["dayStart"] = dayStart
        state["dayBolus"] = dayBolus
        state["dayBasal"] = dayBasal
        state["timeZoneOffset"] = timeZoneOffset
        state["recordLog"] = try? JSONEncoder().encode(recordLog)

        do {
            state["basal"] = try JSONEncoder().encode(basal)
        } catch {}

        return state
    }

    var currentModelIndex: Int

    /// Goes up by one with every patch activated, as on real patches. Kept below 0x10000: records and statuses carry
    /// only its low two bytes.
    var patchId: UInt32
    var patchState: PatchState

    /// The patch's event log - see `MedtrumKitDelivery.swift` for what writes to it. Written on the pump manager's
    /// queue only, read by the UI too: behind a lock, each change made in one go (`updateRecordLog`).
    var recordLog: MedtrumKitRecordLog {
        recordLogLock.withLock { _recordLog }
    }

    @discardableResult func updateRecordLog<Result>(_ change: (inout MedtrumKitRecordLog) -> Result) -> Result {
        recordLogLock.withLock { change(&_recordLog) }
    }

    private var _recordLog: MedtrumKitRecordLog
    private let recordLogLock = NSLock()
    /// The record number a status's basal field and a command's answer carry for the running basal segment: the newest
    /// record as it started - the record of the segment it replaced
    var basalSequence: UInt16

    /// The base's serial number, as records carry it
    var serialNumber: UInt32 {
        currentModelIndex == 0 ? 0x4A12_D828 : 0x52DF_1614
    }

    var activatedAt: Date?
    var expiresAt: Date? {
        guard let activatedAt else {
            return nil
        }

        return activatedAt.addingTimeInterval(.hours(80))
    }

    var basal: [BasalItem]
    var reservoirLevel: Double

    var basalSince: Date
    var suspendedSince: Date?
    var suspendedDuration: TimeInterval?
    var tempBasalRate: Double?
    var tempBasalStart: Date?
    var tempBasalDuration: TimeInterval?

    var bolusProgress: Double?
    var bolusTotal: Double?
    /// When the running bolus started - nil while none runs
    var bolusStart: Date?
    /// The record number the SetBolus answer named: the next one then. The bolus is written under the next number
    /// as it ends - this one, or a later one if the patch wrote other records meanwhile.
    var bolusAnsweredNumber: UInt16?
    /// A full status repeats the last bolus's completion
    var lastBolusDelivered: Double
    var lastBolusCause: UInt8

    /// The day the totals of the next TDD record are counted for (the patch's midnight), and those totals
    var dayStart: Date?
    var dayBolus: Double
    var dayBasal: Double

    /// The patch's offset from UTC in minutes, as the phone set it (SetTimeZone): its midnight and the blocks of its
    /// schedule follow it. Until the phone sets one, the Mac's.
    var timeZoneOffset: Int?

    /// The patch's calendar: the zone the phone set
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneOffset.flatMap { TimeZone(secondsFromGMT: $0 * 60) } ?? .current
        return calendar
    }

    var primeProgress: UInt8?

    var voltageA: Double = 6.1
    var voltageB: Double = 2.80

    // Patch settings
    var expirationTimer: UInt8 = 1
    var alarmSettings: AlarmSettings = .None
    var hourlyMaxInsulin: UInt16 = 20
    var dailyMaxInsulin: UInt16 = 180

    var currentBaseBasalRate: Double {
        scheduledRate(at: Date())
    }

    func scheduledRate(at date: Date) -> Double {
        guard !basal.isEmpty else {
            // Prevent crash if basalSchedule isnt set
            return 0
        }

        let startOfDay = calendar.startOfDay(for: date)
        let timeInterval = date.timeIntervalSince(startOfDay)

        let index = (basal.firstIndex(where: { $0.start > timeInterval }) ?? basal.count) - 1
        return basal.indices.contains(index) ? basal[index].rate : basal[0].rate
    }
}

public enum PatchState: UInt8, Codable {
    case none = 0
    case idle = 1
    case filled = 2
    case priming = 3
    case primed = 4
    case ejecting = 5
    case ejected = 6
    case active = 32
    case active_alt = 33
    case lowBgSuspended = 64
    case lowBgSuspended2 = 65
    case autoSuspended = 66
    case hourlyMaxSuspended = 67
    case dailyMaxSuspended = 68
    case suspended = 69
    case paused = 70
    case occlusion = 96
    case expired = 97
    case reservoirEmpty = 98
    case patchFault = 99
    case patchFaultd2 = 100
    case baseFault = 101
    case batteryOut = 102
    case noCalibration = 103
    case stopped = 128

    var title: String {
        switch self {
        case .none: return "None"
        case .idle: return "Idle"
        case .filled: return "Filled"
        case .priming: return "Priming"
        case .primed: return "Primed"
        case .ejecting: return "Ejecting"
        case .ejected: return "Ejected"
        case .active: return "Active"
        case .active_alt: return "Active_alt"
        case .lowBgSuspended: return "LowBgSuspended"
        case .lowBgSuspended2: return "LowBgSuspended2"
        case .autoSuspended: return "AutoSuspended"
        case .hourlyMaxSuspended: return "HourlyMaxSuspended"
        case .dailyMaxSuspended: return "DailyMaxSuspended"
        case .suspended: return "Suspended"
        case .paused: return "Paused"
        case .occlusion: return "Occlusion"
        case .expired: return "Expired"
        case .reservoirEmpty: return "ReservoirEmpty"
        case .patchFault: return "PatchFault"
        case .patchFaultd2: return "PatchFaultd2"
        case .baseFault: return "BaseFault"
        case .batteryOut: return "BatteryOut"
        case .noCalibration: return "NoCalibration"
        case .stopped: return "Stopped"
        }
    }

    var isSuspended: Bool {
        switch self {
        case .autoSuspended,
             .dailyMaxSuspended,
             .hourlyMaxSuspended,
             .lowBgSuspended,
             .lowBgSuspended2,
             .suspended:
            return true
        default:
            return false
        }
    }
}
