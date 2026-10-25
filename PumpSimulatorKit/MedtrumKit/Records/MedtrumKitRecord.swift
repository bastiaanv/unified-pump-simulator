import Foundation

/// One entry of the patch's own event log. The patch numbers a record per delivery event as the event ends - a bolus,
/// a basal segment - plus a few bookkeeping ones (time sync, alarm, the daily total), all on one counter.
///
/// The layout is the one AndroidAPS (`GetRecordPacket.kt`) and MedtrumKit (`GetRecordPacket.swift`) read, checked
/// against answers of real patches: a 12 byte header, then the payload of the record type.
struct MedtrumKitRecord: Codable, Identifiable {
    var number: UInt16
    var kind: Kind
    /// When the simulator wrote it
    var writtenAt: Date

    var id: UInt16 {
        number
    }

    enum Kind: Codable {
        case bolus(Bolus)
        case basal(Basal)
        case tdd(Tdd)
        /// A record the patch writes whose payload nobody decodes (time sync, alarm, ...): written as zeros
        case other(type: UInt8)
    }

    struct Bolus: Codable {
        /// The completion type the patch reports: 0 delivered in full, 32 cancelled, 9 cut by a halt
        var cause: UInt8
        var start: Date
        var requested: Double
        var delivered: Double
    }

    struct Basal: Codable {
        /// `BasalType` raw value
        var type: UInt8
        var endReason: BasalEndReason
        var start: Date
        var end: Date
        var rate: Double
        var delivered: Double
    }

    struct Tdd: Codable {
        /// Local midnight the day began
        var dayStart: Date
        /// Minutes east of UTC
        var timeZoneOffset: Int
        /// How much of the day the patch was running
        var minutes: UInt16
        var total: Double
        var basal: Double
    }

    static let typeBolus: UInt8 = 1
    static let typeBasal: UInt8 = 2
    static let typeAlarm: UInt8 = 3
    static let typeTimeSync: UInt8 = 5
    static let typeAuto3: UInt8 = 8
    static let typeTdd: UInt8 = 9
    /// Unknown, the patch writes one at midnight before the TDD
    static let typeMidnight: UInt8 = 10

    var recordType: UInt8 {
        switch kind {
        case .bolus: Self.typeBolus
        case .basal: Self.typeBasal
        case .tdd: Self.typeTdd
        case let .other(type): type
        }
    }

    var typeName: String {
        switch recordType {
        case Self.typeBolus: "BOLUS"
        case Self.typeBasal: "BASAL"
        case Self.typeAlarm: "ALARM"
        case Self.typeTimeSync: "TIME_SYNC"
        case Self.typeAuto3: "AUTO3"
        case Self.typeTdd: "TDD"
        default: "TYPE \(recordType)"
        }
    }

    /// The GET_RECORD answer body (after the response code) carrying this record
    func encode(serial: UInt32, patchId: UInt32) -> Data {
        Self.header(valid: true, length: payload.count, type: recordType, serial: serial, patchId: patchId, number: number) +
            payload
    }

    /// What the patch answers for a slot it holds no record in. Nothing tells how a real patch answers that; this is
    /// an empty slot - no 0xAA header byte - which AndroidAPS logs as "Invalid record header" and MedtrumKit reads
    /// as an invalid record, asking again and then skipping it.
    static func emptySlot(number: UInt16, serial: UInt32, patchId: UInt32) -> Data {
        header(valid: false, length: 16, type: 0, serial: serial, patchId: patchId, number: number) + Data(count: 16)
    }

    /// Header (6..<18 of the answer): 0xAA, the record's length counting the header, its type, 0xFF, the base's serial
    /// number, the low two bytes of the patch id, the record number
    private static func header(valid: Bool, length: Int, type: UInt8, serial: UInt32, patchId: UInt32, number: UInt16) -> Data {
        var data = valid ? Data([0xAA, UInt8(12 + length), type, 0xFF]) : Data(count: 4)
        data.append(serial.toData())
        data.append(UInt16(truncatingIfNeeded: patchId).toData())
        data.append(number.toData())
        return data
    }

    private var payload: Data {
        switch kind {
        case let .bolus(bolus):
            // 28 bytes: type (1 = normal, no wizard), cause, 2 unknown, start, requested, delivered, extended amount,
            // duration and delivered, carbs, glucose, IOB, 4 unknown
            var data = Data([1, bolus.cause, 0, 0])
            data.append(bolus.start.toMedtrumSeconds())
            data.append(Self.steps(bolus.requested))
            data.append(Self.steps(bolus.delivered))
            data.append(Data(count: 16))
            return data

        case let .basal(basal):
            // 16 bytes: start, end, type, end reason, rate, delivered, percent. Real patches put the rate in steps in
            // the percent of an absolute temp basal, anything in a standard one's.
            var data = basal.start.toMedtrumSeconds()
            data.append(basal.end.toMedtrumSeconds())
            data.append(contentsOf: [basal.type, basal.endReason.rawValue])
            data.append(Self.steps(basal.rate))
            data.append(Self.steps(basal.delivered))
            data.append(basal.type == BasalType.ABSOLUTE_TEMP.rawValue ? Self.steps(basal.rate) : UInt16(0).toData())
            return data

        case let .tdd(tdd):
            // 68 bytes: day start, time zone offset, minutes, glucose record time, then floats: total, basal, glucose
            // and 11 more nobody decodes
            var data = tdd.dayStart.toMedtrumSeconds()
            data.append(UInt16(truncatingIfNeeded: tdd.timeZoneOffset).toData())
            data.append(tdd.minutes.toData())
            data.append(Data(count: 4))
            data.append(Float(tdd.total).bitPattern.toData())
            data.append(Float(tdd.basal).bitPattern.toData())
            data.append(Data(count: 48))
            return data

        case .other:
            return Data(count: 16)
        }
    }

    /// Units in the patch's 0.05 U steps
    static func steps(_ units: Double) -> Data {
        UInt16(max(0, (units / 0.05).rounded())).toData()
    }
}
