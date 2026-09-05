import Foundation

/// Persisted state for the Tandem Mobi simulator. Round-trips through
/// `StateRawValue` the same way `MedtrumKitState` does, and additionally stores
/// the JPAKE pairing artifacts so a reconnecting central that believes it is
/// already paired can skip the full handshake.
class TandemState {
    init(rawValue: StateRawValue) {
        reservoirLevel = rawValue["reservoirLevel"] as? Double ?? 100
        batteryPercent = rawValue["batteryPercent"] as? UInt8 ?? 100
        activatedAt = rawValue["activatedAt"] as? Date
        timeSinceReset = rawValue["timeSinceReset"] as? UInt32 ?? 0
        suspendedSince = rawValue["suspendedSince"] as? Date
        suspendedDuration = rawValue["suspendedDuration"] as? TimeInterval
        tempBasalRate = rawValue["tempBasalRate"] as? Double
        tempBasalStart = rawValue["tempBasalStart"] as? Date
        tempBasalDuration = rawValue["tempBasalDuration"] as? TimeInterval
        bolusProgress = rawValue["bolusProgress"] as? Double
        bolusTotal = rawValue["bolusTotal"] as? Double
        bolusIdCount = rawValue["bolusIdCount"] as? UInt16 ?? 0
        serialNumber = rawValue["serialNumber"] as? UInt32 ?? 0x0052_0001
        maxBasalMilliunits = rawValue["maxBasalMilliunits"] as? UInt32 ?? 1000
        maxBolusMilliunits = rawValue["maxBolusMilliunits"] as? UInt16 ?? 5000

        if let data = rawValue["derivedSecret"] as? Data {
            derivedSecret = data
        }
        if let data = rawValue["serverNonce3"] as? Data {
            serverNonce3 = data
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
        state["reservoirLevel"] = reservoirLevel
        state["batteryPercent"] = batteryPercent
        state["activatedAt"] = activatedAt
        state["timeSinceReset"] = timeSinceReset
        state["suspendedSince"] = suspendedSince
        state["suspendedDuration"] = suspendedDuration
        state["tempBasalRate"] = tempBasalRate
        state["tempBasalStart"] = tempBasalStart
        state["tempBasalDuration"] = tempBasalDuration
        state["bolusProgress"] = bolusProgress
        state["bolusTotal"] = bolusTotal
        state["bolusIdCount"] = bolusIdCount
        state["serialNumber"] = serialNumber
        state["maxBasalMilliunits"] = maxBasalMilliunits
        state["maxBolusMilliunits"] = maxBolusMilliunits
        state["derivedSecret"] = derivedSecret
        state["serverNonce3"] = serverNonce3

        do {
            state["basal"] = try JSONEncoder().encode(basal)
        } catch {}

        return state
    }

    var reservoirLevel: Double
    var batteryPercent: UInt8

    var activatedAt: Date?
    var timeSinceReset: UInt32

    var basal: [BasalItem]
    var suspendedSince: Date?
    var suspendedDuration: TimeInterval?
    var tempBasalRate: Double?
    var tempBasalStart: Date?
    var tempBasalDuration: TimeInterval?

    var bolusProgress: Double?
    var bolusTotal: Double?

    var bolusIdCount: UInt16
    var serialNumber: UInt32
    var maxBasalMilliunits: UInt32
    var maxBolusMilliunits: UInt16

    // JPAKE pairing artifacts
    var derivedSecret: Data?
    var serverNonce3: Data?

    var currentBaseBasalRate: Double {
        guard !basal.isEmpty else { return 0 }
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let nowTimeInterval = now.timeIntervalSince(startOfDay)
        let index = (basal.firstIndex(where: { $0.start > nowTimeInterval }) ?? basal.count) - 1
        return basal.indices.contains(index) ? basal[index].rate : basal[0].rate
    }

    var nextBolusId: UInt16 {
        bolusIdCount &+= 1
        return bolusIdCount
    }

    func hasPairingArtifacts() -> Bool {
        if let secret = derivedSecret, !secret.isEmpty, let nonce = serverNonce3, !nonce.isEmpty {
            return true
        }
        return false
    }
}
