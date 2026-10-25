import Foundation

/// The patch's records, as the simulator lists them
extension MedtrumKitPumpManager {
    /// The current patch's records, newest first
    func recordList() -> PumpManagerList {
        PumpManagerList(
            title: "Patch records",
            columns: ["#", "Type", "Start", "End", "Amounts", "Details"],
            emptyText: "No records: the patch writes them once activated"
        ) { [weak self] in
            guard let self else {
                return []
            }

            var rows: [[String]] = []
            if let start = state.bolusStart, let total = state.bolusTotal {
                rows.append([
                    "",
                    "BOLUS",
                    Self.format(start),
                    "running",
                    "requested \(Self.units(total))",
                    "answer named #\(state.bolusAnsweredNumber.map(String.init) ?? "?"), written as it ends",
                ])
            }

            rows += state.recordLog.records.suffix(Self.listedRecords).reversed().map(Self.row)
            return rows
        }
    }

    private static let listedRecords = 200

    private static func row(_ record: MedtrumKitRecord) -> [String] {
        let number = "\(record.number)"

        switch record.kind {
        case let .bolus(bolus):
            let cause = switch bolus.cause {
            case MedtrumKitPackets.bolusCompleted: "completed"
            case MedtrumKitPackets.bolusCancelled: "cancelled"
            case MedtrumKitPackets.bolusInterrupted: "interrupted"
            default: "cause \(bolus.cause)"
            }
            return [
                number,
                record.typeName,
                format(bolus.start),
                format(record.writtenAt),
                "requested \(units(bolus.requested)), delivered \(units(bolus.delivered))",
                cause,
            ]

        case let .basal(basal):
            let type = BasalType(rawValue: basal.type).map { "\($0)" } ?? "type \(basal.type)"
            return [
                number,
                record.typeName,
                format(basal.start),
                format(basal.end),
                "\(units(basal.rate))/h, delivered \(units(basal.delivered))",
                "\(type), \(basal.endReason)",
            ]

        case let .tdd(tdd):
            return [
                number,
                record.typeName,
                "day \(format(tdd.dayStart))",
                format(record.writtenAt),
                "total \(units(tdd.total)), basal \(units(tdd.basal))",
                "\(tdd.minutes) min",
            ]

        case .other:
            return [number, record.typeName, format(record.writtenAt), "", "", ""]
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private static func format(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func units(_ value: Double) -> String {
        String(format: "%.2f U", value)
    }
}
