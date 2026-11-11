import Foundation

/// The records of the current patch, numbered from 1 on one counter for every record type.
///
/// A record takes the next number as it is written - a bolus as it ends, a basal segment as it ends - so numbers follow
/// the order records are written in, and every number up to the newest names a record. The SetBolus answer names the
/// number the bolus will get if nothing else is written first (`nextNumber`) without taking it: a record the patch
/// writes while the bolus runs takes that number, the bolus the one after it.
///
/// Records are plain values in an array, looked up by number. Record faults (`RecordReadFault`) leave them as they
/// are: they change what a GET_RECORD answers for one.
struct MedtrumKitRecordLog: Codable {
    /// Older records are dropped past this - MedtrumKit reads at most the last 20 of a patch it adopts
    static let capacity = 1000

    private(set) var records: [MedtrumKitRecord] = []

    /// The newest record written - what statuses report in their storage field
    var newestWritten: UInt16 {
        records.last?.number ?? 0
    }

    /// The number the next record written gets
    var nextNumber: UInt16 {
        newestWritten &+ 1
    }

    func record(_ number: UInt16) -> MedtrumKitRecord? {
        records.last { $0.number == number }
    }

    /// Writes a record under the next number
    @discardableResult mutating func append(_ kind: MedtrumKitRecord.Kind, at date: Date = .now) -> MedtrumKitRecord {
        let record = MedtrumKitRecord(number: nextNumber, kind: kind, writtenAt: date)
        records.append(record)

        if records.count > Self.capacity {
            records.removeFirst(records.count - Self.capacity)
        }

        return record
    }

    /// A new patch: its records start again from 1
    mutating func reset() {
        records = []
    }
}
