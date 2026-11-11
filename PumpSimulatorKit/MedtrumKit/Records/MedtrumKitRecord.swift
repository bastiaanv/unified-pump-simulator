import Foundation

/// One entry of the patch's own event log. The patch numbers a record per delivery event as the event ends - a bolus,
/// a basal segment - plus a few bookkeeping ones (time sync, alarm, the daily total), all on one counter.
///
/// The layout is the one AndroidAPS (`GetRecordPacket.kt`) and MedtrumKit (`GetRecordPacket.swift`) read, checked
/// against answers of real patches: a 12 byte header, the payload of the record type, then a CRC-32/MPEG-2 of both
/// (`Crc32Mpeg2`). The header's length byte counts all three.
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
        /// Type 3: an alarm the patch raised - a suspend, a halt, a warning such as low reservoir
        case alarm(Alarm)
        /// Type 8: delivery resumed, after the alarm record of a suspend
        case resumed
        /// Type 10: written at the patch's midnight, before the TDD, and at a fault
        case daily(Daily)
        /// Type 12: the base's lifetime counters, every 8 h
        case baseCounters(BaseCounters)
        /// A record whose payload nobody decodes (time sync, ...): written as zeros
        case other(type: UInt8)
    }

    struct Alarm: Codable {
        /// The alarm's bit in the status's alarm field: 2 low reservoir, 4 delivery suspended, 6 occlusion, 8
        /// reservoir empty
        var bit: UInt8
        /// Seconds since the patch was activated - real patches count from its first power-up on the base
        var patchAge: UInt32
    }

    struct Daily: Codable {
        /// Minutes east of UTC: the zone the patch runs in
        var timeZoneOffset: Int
    }

    struct BaseCounters: Codable {
        /// Insulin the base has delivered over every patch, in 0.05 U steps
        var lifetimeSteps: UInt32
        var operatingHours: UInt16
        var patchesUsed: UInt16
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
    static let typeResumed: UInt8 = 8
    static let typeTdd: UInt8 = 9
    static let typeDaily: UInt8 = 10
    static let typeBaseCounters: UInt8 = 12

    /// Alarm bits, as the status's alarm field and the alarm record carry them
    static let alarmLowReservoir: UInt8 = 2
    static let alarmSuspended: UInt8 = 4
    static let alarmOcclusion: UInt8 = 6
    static let alarmReservoirEmpty: UInt8 = 8

    var recordType: UInt8 {
        switch kind {
        case .bolus: Self.typeBolus
        case .basal: Self.typeBasal
        case .tdd: Self.typeTdd
        case .alarm: Self.typeAlarm
        case .resumed: Self.typeResumed
        case .daily: Self.typeDaily
        case .baseCounters: Self.typeBaseCounters
        case let .other(type): type
        }
    }

    var typeName: String {
        switch recordType {
        case Self.typeBolus: "BOLUS"
        case Self.typeBasal: "BASAL"
        case Self.typeAlarm: "ALARM"
        case Self.typeTimeSync: "TIME_SYNC"
        case Self.typeResumed: "RESUMED"
        case Self.typeTdd: "TDD"
        case Self.typeDaily: "DAILY"
        case Self.typeBaseCounters: "BASE"
        default: "TYPE \(recordType)"
        }
    }

    /// The GET_RECORD answer body (after the response code) carrying this record. `corruptCrc`: its CRC off by one, as a
    /// record damaged on the way would be. `truncated`: at most 8 bytes of its payload, no CRC - shorter than any record
    /// type's fields MedtrumKit reads (a TDD's half would still parse) - its length byte as for the whole record.
    func encode(serial: UInt32, patchId: UInt32, corruptCrc: Bool = false, truncated: Bool = false) -> Data {
        let payload = payload
        if truncated {
            return Self.header(
                valid: true,
                length: payload.count,
                type: recordType,
                serial: serial,
                patchId: patchId,
                number: number
            ) + payload.prefix(min(payload.count / 2, 8))
        }
        let record = Self.header(
            valid: true,
            length: payload.count,
            type: recordType,
            serial: serial,
            patchId: patchId,
            number: number
        ) + payload
        let crc = Crc32Mpeg2.calculate(record)
        return record + (corruptCrc ? crc ^ 1 : crc).toData()
    }

    /// What the patch answers for a slot it holds no record in. Nothing tells how a real patch answers that; this is
    /// an empty slot - no 0xAA header byte - which AndroidAPS logs as "Invalid record header" and MedtrumKit reads
    /// as an invalid record, asking again and then skipping it.
    static func emptySlot(number: UInt16, serial: UInt32, patchId: UInt32) -> Data {
        header(valid: false, length: 16, type: 0, serial: serial, patchId: patchId, number: number) + Data(count: 16)
    }

    /// Header (6..<18 of the answer): 0xAA, the record's length counting the header, the payload and the CRC, its
    /// type, 0xFF (0x00 in a BASE record, as real patches write it), the base's serial number, the low two bytes of the
    /// patch id, the record number
    private static func header(valid: Bool, length: Int, type: UInt8, serial: UInt32, patchId: UInt32, number: UInt16) -> Data {
        var data = valid ? Data([0xAA, UInt8(12 + length + 4), type, type == typeBaseCounters ? 0x00 : 0xFF]) : Data(count: 4)
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
            // 72 bytes: day start, time zone offset, minutes, glucose record time, then floats: total, basal, glucose
            // and 12 more nobody decodes
            var data = tdd.dayStart.toMedtrumSeconds()
            data.append(UInt16(truncatingIfNeeded: tdd.timeZoneOffset).toData())
            data.append(tdd.minutes.toData())
            data.append(Data(count: 4))
            data.append(Float(tdd.total).bitPattern.toData())
            data.append(Float(tdd.basal).bitPattern.toData())
            data.append(Data(count: 52))
            return data

        case let .alarm(alarm):
            // 16 bytes: patch age, time, the alarm's bit, 00, ffff, two values nobody decodes (5 in a suspend's)
            var data = alarm.patchAge.toData()
            data.append(writtenAt.toMedtrumSeconds())
            data.append(contentsOf: [alarm.bit, 0x00, 0xFF, 0xFF])
            data.append(UInt16(alarm.bit == Self.alarmSuspended ? 5 : 0).toData())
            data.append(UInt16(0).toData())
            return data

        case .resumed:
            // 8 bytes: 01 00 ff ff, then the time
            return Data([0x01, 0x00, 0xFF, 0xFF]) + writtenAt.toMedtrumSeconds()

        case let .daily(daily):
            // 20 bytes: time, time zone offset, ffff, two floats nobody decodes, four zero bytes
            var data = writtenAt.toMedtrumSeconds()
            data.append(UInt16(truncatingIfNeeded: daily.timeZoneOffset).toData())
            data.append(contentsOf: [0xFF, 0xFF])
            data.append(Data(count: 12))
            return data

        case let .baseCounters(counters):
            // 12 bytes: time, lifetime insulin in steps, operating hours, patches used
            var data = writtenAt.toMedtrumSeconds()
            data.append(counters.lifetimeSteps.toData())
            data.append(counters.operatingHours.toData())
            data.append(counters.patchesUsed.toData())
            return data

        case let .other(type):
            // As long as the decoded kinds of the same type - an alarm, a resume or a daily record saved before they
            // were - or 16 bytes
            switch type {
            case Self.typeResumed: return Data(count: 8)
            case Self.typeDaily: return Data(count: 20)
            case Self.typeBaseCounters: return Data(count: 12)
            default: return Data(count: 16)
            }
        }
    }

    /// Units in the patch's 0.05 U steps
    static func steps(_ units: Double) -> Data {
        UInt16(max(0, (units / 0.05).rounded())).toData()
    }
}
