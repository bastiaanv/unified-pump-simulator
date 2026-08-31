import Foundation

/// A single telemetry / history record stored on the pump (RACP report, `packets/06 §3`).
/// Wire header is 11 bytes: `[type u16][seq u32][baseTime u32][sessionId u8]` + data.
struct HistoryRecord: Codable, Identifiable {
    var id = UUID()
    var type: UInt16
    var seqNumber: UInt32
    var baseTime: UInt32
    var sessionId: UInt8
    var data: Data
}

/// Row types for the MiniMed-specific settings the app reads/writes
/// (`packets/03 §2.5`, `packets/05 §4.1`).
struct CarbRatioRow: Codable, Identifiable {
    var id = UUID()
    var start: UInt16
    var end: UInt16
}

struct ISFRow: Codable, Identifiable {
    var id = UUID()
    var a: UInt16
    var b: UInt16
}

struct BgTargetRow: Codable, Identifiable {
    var id = UUID()
    var a: UInt16
    var b: UInt16
    var c: UInt16
}

/// A configured basal pattern. Each segment is `{duration u16}{rate u32 mU}` (`packets/03 §2.2`).
struct BasalPattern: Codable {
    var id: UInt8
    var name: String
    var segments: [BasalPatternSegment]
}

struct BasalPatternSegment: Codable {
    var duration: UInt16 // minutes
    var rateMilliUnits: UInt32 // u/hr in milli-units
    var rate: Double {
        Double(rateMilliUnits) / 1000.0
    }
}

/// Persistable state for a MiniMed Flex (a classic tube pump).
class MiniMedKitState {
    init(rawValue: StateRawValue) {
        currentModelIndex = rawValue["currentModelIndex"] as? Int ?? 0
        activatedAt = rawValue["activatedAt"] as? Date
        serialNumber = rawValue["serialNumber"] as? String ?? "SN1234567"
        reservoirLevel = rawValue["reservoirLevel"] as? Double ?? 180.0
        batteryLevel = rawValue["batteryLevel"] as? Double ?? 100.0
        basalSince = rawValue["basalSince"] as? Date ?? Date.now
        suspendedSince = rawValue["suspendedSince"] as? Date
        tempBasalRate = rawValue["tempBasalRate"] as? Double
        tempBasalStart = rawValue["tempBasalStart"] as? Date
        tempBasalDuration = rawValue["tempBasalDuration"] as? TimeInterval
        bolusProgress = rawValue["bolusProgress"] as? Double
        bolusTotal = rawValue["bolusTotal"] as? Double
        txSeq = rawValue["txSeq"] as? UInt8 ?? 0
        rxSeq = rawValue["rxSeq"] as? UInt8 ?? 0
        passkey = rawValue["passkey"] as? String ?? "123456"
        maxBolus = rawValue["maxBolus"] as? Double ?? 25.0
        maxBasal = rawValue["maxBasal"] as? Double ?? 10.0
        activeInsulinTime = rawValue["activeInsulinTime"] as? TimeInterval ?? .hours(4)

        basal = Self.decodeArray(rawValue["basal"], type: [BasalItem].self) ?? []
        historyRecords = Self.decodeArray(rawValue["historyRecords"], type: [HistoryRecord].self) ?? []
        carbRatio = Self.decodeArray(rawValue["carbRatio"], type: [CarbRatioRow].self) ?? []
        isf = Self.decodeArray(rawValue["isf"], type: [ISFRow].self) ?? []
        bgTarget = Self.decodeArray(rawValue["bgTarget"], type: [BgTargetRow].self) ?? []
        basalPatterns = Self.decodeArray(rawValue["basalPatterns"], type: [BasalPattern].self) ?? []
    }

    private static func decodeArray<T: Decodable>(_ value: Any?, type: T.Type) -> T? {
        guard let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encodeArray<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    func getRaw() -> StateRawValue {
        var state: StateRawValue = [:]
        state["currentModelIndex"] = currentModelIndex
        state["activatedAt"] = activatedAt
        state["serialNumber"] = serialNumber
        state["reservoirLevel"] = reservoirLevel
        state["batteryLevel"] = batteryLevel
        state["basalSince"] = basalSince
        state["suspendedSince"] = suspendedSince
        state["tempBasalRate"] = tempBasalRate
        state["tempBasalStart"] = tempBasalStart
        state["tempBasalDuration"] = tempBasalDuration
        state["bolusProgress"] = bolusProgress
        state["bolusTotal"] = bolusTotal
        state["txSeq"] = txSeq
        state["rxSeq"] = rxSeq
        state["passkey"] = passkey
        state["maxBolus"] = maxBolus
        state["maxBasal"] = maxBasal
        state["activeInsulinTime"] = activeInsulinTime
        if let data = Self.encodeArray(basal) {
            state["basal"] = data
        }
        if let data = Self.encodeArray(historyRecords) {
            state["historyRecords"] = data
        }
        if let data = Self.encodeArray(carbRatio) {
            state["carbRatio"] = data
        }
        if let data = Self.encodeArray(isf) {
            state["isf"] = data
        }
        if let data = Self.encodeArray(bgTarget) {
            state["bgTarget"] = data
        }
        if let data = Self.encodeArray(basalPatterns) {
            state["basalPatterns"] = data
        }
        return state
    }

    var currentModelIndex: Int
    var activatedAt: Date?

    var serialNumber: String
    var passkey: String

    var reservoirLevel: Double
    var batteryLevel: Double
    var basal: [BasalItem]
    var basalSince: Date
    var suspendedSince: Date?
    var tempBasalRate: Double?
    var tempBasalStart: Date?
    var tempBasalDuration: TimeInterval?

    var bolusProgress: Double?
    var bolusTotal: Double?

    /// Classic pump — non-expiring.
    var expiresAt: Date? {
        nil
    }

    // MiniMed-specific settings.
    var maxBolus: Double
    var maxBasal: Double
    var carbRatio: [CarbRatioRow]
    var isf: [ISFRow]
    var bgTarget: [BgTargetRow]
    var activeInsulinTime: TimeInterval
    var basalPatterns: [BasalPattern]

    // Bolt-on counters for RACP/SRCP + history.
    var historyRecords: [HistoryRecord]
    var nextRecordSeq: UInt32 {
        UInt32(historyRecords.count) + 1
    }

    var txSeq: UInt8
    var rxSeq: UInt8

    var currentBaseBasalRate: Double {
        guard !basal.isEmpty else { return 0 }
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let nowInterval = now.timeIntervalSince(startOfDay)
        let index = (basal.firstIndex(where: { $0.start > nowInterval }) ?? basal.count) - 1
        return basal.indices.contains(index) ? basal[index].rate : basal[0].rate
    }

    func addHistory(type: UInt16, data: Data) {
        let record = HistoryRecord(
            type: type,
            seqNumber: nextRecordSeq,
            baseTime: UInt32(Date().timeIntervalSince1970),
            sessionId: 1,
            data: data
        )
        historyRecords.append(record)
    }
}
