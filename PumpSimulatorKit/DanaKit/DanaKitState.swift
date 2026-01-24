import Foundation

class DanaKitState {
    init(rawValue: StateRawValue) {
        reservoirLevel = rawValue["reservoirLevel"] as? Double ?? 300
        batteryPercentage = rawValue["batteryPercentage"] as? UInt8 ?? 100
        suspendedSince = rawValue["suspendedSince"] as? Date
        tempBasalPercentage = rawValue["tempBasalPercentage"] as? UInt16
        tempBasalStart = rawValue["tempBasalStart"] as? Date
        tempBasalDuration = rawValue["tempBasalDuration"] as? TimeInterval
        historyUploadMode = rawValue["historyUploadMode"] as? Bool ?? false
        timeDisplayIn12H = rawValue["timeDisplayIn12H"] as? Bool ?? false
        buttonScroll = rawValue["buttonScroll"] as? Bool ?? false
        lcdOnInSeconds = rawValue["lcdOnInSeconds"] as? UInt8 ?? 5
        backlightOnInSeconds = rawValue["backlightOnInSeconds"] as? UInt8 ?? 0
        selectedLanguage = rawValue["selectedLanguage"] as? UInt8 ?? 1
        shutdownInHours = rawValue["shutdownInHours"] as? UInt8 ?? 100
        lowReservoirWarning = rawValue["lowReservoirWarning"] as? UInt8 ?? 20
        cannulaVolume = rawValue["cannulaVolume"] as? UInt16 ?? 1
        refillAmount = rawValue["refillAmount"] as? UInt16 ?? 300
        targetBg = rawValue["targetBg"] as? UInt16 ?? 5

        if let rawPumpModel = rawValue["pumpModel"] as? DanaPump.RawValue {
            pumpModel = DanaPump(rawValue: rawPumpModel) ?? .DanaI
        } else {
            pumpModel = .DanaI
        }

        if let rawAlarmType = rawValue["alarmType"] as? AlarmType.RawValue {
            alarmType = AlarmType(rawValue: rawAlarmType) ?? .Both
        } else {
            alarmType = .Both
        }

        if let rawBgUnit = rawValue["bgUnit"] as? BgUnit.RawValue {
            bgUnit = BgUnit(rawValue: rawBgUnit) ?? .MgDl
        } else {
            bgUnit = .MgDl
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
    }

    func getRaw() -> StateRawValue {
        var state: StateRawValue = [:]
        state["pumpModel"] = pumpModel.rawValue
        state["batteryPercentage"] = batteryPercentage
        state["suspendedSince"] = suspendedSince
        state["tempBasalPercentage"] = tempBasalPercentage
        state["tempBasalStart"] = tempBasalStart
        state["tempBasalDuration"] = tempBasalDuration
        state["historyUploadMode"] = historyUploadMode
        state["timeDisplayIn12H"] = timeDisplayIn12H
        state["buttonScroll"] = buttonScroll
        state["alarmType"] = alarmType.rawValue
        state["lcdOnInSeconds"] = lcdOnInSeconds
        state["selectedLanguage"] = selectedLanguage
        state["bgUnit"] = bgUnit.rawValue
        state["shutdownInHours"] = shutdownInHours
        state["lowReservoirWarning"] = lowReservoirWarning
        state["cannulaVolume"] = cannulaVolume
        state["refillAmount"] = refillAmount
        state["targetBg"] = targetBg

        do {
            state["basal"] = try JSONEncoder().encode(basal)
        } catch {}

        return state
    }

    var pumpModel: DanaPump
    var basal: [BasalItem]

    var suspendedSince: Date?
    var tempBasalPercentage: UInt16?
    var tempBasalStart: Date?
    var tempBasalDuration: TimeInterval?

    var reservoirLevel: Double
    var batteryPercentage: UInt8

    var historyUploadMode: Bool

    // User options
    var timeDisplayIn12H: Bool
    var buttonScroll: Bool
    var alarmType: AlarmType
    var lcdOnInSeconds: UInt8
    var backlightOnInSeconds: UInt8
    var selectedLanguage: UInt8
    var bgUnit: BgUnit
    var shutdownInHours: UInt8
    var lowReservoirWarning: UInt8
    var cannulaVolume: UInt16
    var refillAmount: UInt16
    var targetBg: UInt16

    var currentBasalRate: Double? {
        let currentTime = Calendar.current.startOfDay(for: Date.now).timeIntervalSinceNow
        return basal.reversed().first(where: { $0.start <= currentTime })?.rate
    }
}
