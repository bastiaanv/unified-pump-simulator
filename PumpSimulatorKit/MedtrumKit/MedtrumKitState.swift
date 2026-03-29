import Foundation

class MedtrumKitState {
    init(rawValue: StateRawValue) {
        currentModelIndex = rawValue["currentModelIndex"] as? Int ?? 0
        activatedAt = rawValue["activatedAt"] as? Date
        reservoirLevel = rawValue["reservoirLevel"] as? Double ?? 0
        suspendedSince = rawValue["suspendedSince"] as? Date
        basalSince = rawValue["basalSince"] as? Date ?? Date.now
        tempBasalPercentage = rawValue["tempBasalPercentage"] as? UInt16
        tempBasalStart = rawValue["tempBasalStart"] as? Date
        tempBasalDuration = rawValue["tempBasalDuration"] as? TimeInterval
        bolusProgress = rawValue["bolusProgress"] as? Double
        bolusTotal = rawValue["bolusTotal"] as? Double
        primeProgress = rawValue["primeProgress"] as? UInt8
        expirationTimer = rawValue["expirationTimer"] as? UInt8 ?? 1
        hourlyMaxInsulin = rawValue["hourlyMaxInsulin"] as? UInt16 ?? 20
        dailyMaxInsulin = rawValue["dailyMaxInsulin"] as? UInt16 ?? 180

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
        state["tempBasalPercentage"] = tempBasalPercentage
        state["tempBasalStart"] = tempBasalStart
        state["tempBasalDuration"] = tempBasalDuration
        state["bolusProgress"] = bolusProgress
        state["bolusTotal"] = bolusTotal
        state["primeProgress"] = primeProgress
        state["expirationTimer"] = expirationTimer
        state["alarmSettings"] = alarmSettings.rawValue
        state["hourlyMaxInsulin"] = hourlyMaxInsulin
        state["dailyMaxInsulin"] = dailyMaxInsulin

        do {
            state["basal"] = try JSONEncoder().encode(basal)
        } catch {}

        return state
    }

    var currentModelIndex: Int

    var patchId: UInt32 = 0
    var patchSequence: UInt16 = 0
    var patchState: PatchState

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
    var tempBasalPercentage: UInt16?
    var tempBasalStart: Date?
    var tempBasalDuration: TimeInterval?

    var bolusProgress: Double?
    var bolusTotal: Double?

    var primeProgress: UInt8?

    var voltageA: Double = 6.1
    var voltageB: Double = 2.80

    // Patch settings
    var expirationTimer: UInt8 = 1
    var alarmSettings: AlarmSettings = .None
    var hourlyMaxInsulin: UInt16 = 20
    var dailyMaxInsulin: UInt16 = 180

    var currentBaseBasalRate: Double {
        guard !basal.isEmpty else {
            // Prevent crash if basalSchedule isnt set
            return 0
        }

        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let nowTimeInterval = now.timeIntervalSince(startOfDay)

        let index = (basal.firstIndex(where: { $0.start > nowTimeInterval }) ?? 24) - 1
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
}
