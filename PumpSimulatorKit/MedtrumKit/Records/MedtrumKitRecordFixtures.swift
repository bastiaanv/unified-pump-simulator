import Foundation

/// A past for a patch, for a driver's history screens: records as a looping patch writes them - temp basals set every
/// few minutes, the schedule between them split at its blocks, a bolus now and then - ending before `end`, in the order
/// they were written. Not what a fresh patch has: the history of a patch adopted after days on another phone.
enum MedtrumKitRecordFixtures {
    /// The newest records are basal segments only: a driver's first sync of a patch reads them (MedtrumKit's
    /// `RecordSyncer.initialBacklog`, 20), and a bolus among them that matches none of its own is taken for one it
    /// failed to count - an alert. A bolus in an older segment is written before the newer segments end, so these
    /// are the newest records.
    static let basalOnlyNewest = 20

    /// `count` records, the newest written before `end`. The same `seed` gives the same records.
    static func history(count: Int, endingBefore end: Date, scheduledRate: Double, seed: UInt64) -> [(
        kind: MedtrumKitRecord.Kind,
        writtenAt: Date
    )] {
        var random = SplitMix64(seed: seed)
        var segments: [(start: Date, end: Date, temp: Double?)] = []
        var boluses: [(start: Date, units: Double)] = []

        // Built backwards from `end`: a segment of 5 to 30 min each, temp basals more often than the schedule, a bolus
        // in about one segment in four - none in the newest `basalOnlyNewest`. Enough of them for `count` records.
        var time = end.addingTimeInterval(-60)
        while segments.count + boluses.count < count {
            let minutes = Double(random.next(in: 5 ... 30))
            let start = time.addingTimeInterval(-minutes * 60)
            let temp = random.next(in: 0 ... 9) < 6 ? Double(random.next(in: 0 ... 40)) * 0.05 : nil
            segments.append((start, time, temp))
            if random.next(in: 0 ... 3) == 0, segments.count > basalOnlyNewest {
                let units = Double(random.next(in: 2 ... 60)) * 0.05
                let offset = Double(random.next(in: 0 ... Int(minutes * 60 / 2)))
                boluses.append((start.addingTimeInterval(offset), units))
            }
            time = start
        }

        var records: [(kind: MedtrumKitRecord.Kind, writtenAt: Date)] = segments.map { segment in
            let rate = segment.temp ?? scheduledRate
            let delivered = MedtrumKitState.roundToSteps(rate * segment.end.timeIntervalSince(segment.start) / 3600)
            return (
                .basal(MedtrumKitRecord.Basal(
                    type: (segment.temp == nil ? BasalType.STANDARD : BasalType.ABSOLUTE_TEMP).rawValue,
                    endReason: .SUCCESS,
                    start: segment.start,
                    end: segment.end,
                    rate: rate,
                    delivered: delivered
                )),
                segment.end
            )
        }
        records += boluses.map { bolus in
            // Written as it ends, at 1.5 U a minute
            let ended = bolus.start.addingTimeInterval(bolus.units / 1.5 * 60)
            return (
                .bolus(MedtrumKitRecord.Bolus(
                    cause: MedtrumKitPackets.bolusCompleted,
                    start: bolus.start,
                    requested: bolus.units,
                    delivered: bolus.units
                )),
                ended
            )
        }

        return Array(records.sorted { $0.writtenAt < $1.writtenAt }.suffix(count))
    }
}

/// A small seeded generator: the same fixture for the same seed
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}
