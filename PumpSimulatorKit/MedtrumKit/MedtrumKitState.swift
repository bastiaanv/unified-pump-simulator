import Foundation

class MedtrumKitState {
    init(rawValue: StateRawValue) {
        currentModelIndex = rawValue["currentModelIndex"] as? Int ?? 0
        activatedAt = rawValue["activatedAt"] as? Date
        expiresAt = rawValue["expiresAt"] as? Date

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
        state["currentModelIndex"] = currentModelIndex
        state["activatedAt"] = activatedAt
        state["expiresAt"] = expiresAt

        do {
            state["basal"] = try JSONEncoder().encode(basal)
        } catch {}

        return state
    }

    var currentModelIndex: Int
    var activatedAt: Date?
    var expiresAt: Date?
    var basal: [BasalItem]
}
