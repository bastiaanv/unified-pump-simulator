import Foundation

class DanaKitState {
    init(rawValue: StateRawValue) {
        reservoirLevel = rawValue["reservoirLevel"] as? Double ?? 300
        batteryPercentage = rawValue["batteryPercentage"] as? UInt8 ?? 100
        suspendedSince = rawValue["suspendedSince"] as? Date
        tempBasalPercentage = rawValue["tempBasalPercentage"] as? UInt8
        tempBasalStart = rawValue["tempBasalStart"] as? Date
        tempBasalDuration = rawValue["tempBasalDuration"] as? TimeInterval
        
        if let rawPumpModel = rawValue["pumpModel"] as? DanaPump.RawValue {
            pumpModel = DanaPump(rawValue: rawPumpModel) ?? .DanaI
        } else {
            pumpModel = .DanaI
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
        
        do {
            state["basal"] = try JSONEncoder().encode(basal)
        } catch {}
        
        return state
    }
    
    var pumpModel: DanaPump
    var basal: [BasalItem]
    
    var suspendedSince: Date?
    var tempBasalPercentage: UInt8?
    var tempBasalStart: Date?
    var tempBasalDuration: TimeInterval?
    
    var reservoirLevel: Double
    var batteryPercentage: UInt8
    
    
    var currentBasalRate: Double? {
        let currentTime = Calendar.current.startOfDay(for: Date.now).timeIntervalSinceNow
        return basal.reversed().first(where: { $0.start <= currentTime })?.rate
    }
}
