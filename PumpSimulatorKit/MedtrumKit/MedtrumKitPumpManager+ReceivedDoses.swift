import Foundation

/// A SetBolus or SetTempBasal as it arrived: the amount in the patch's 0.05 U steps - all a command carries - and what
/// the patch did with it. A driver that sends 1.08 U/h sends 21 steps or 22: this shows which.
struct ReceivedDose {
    let at: Date
    let command: String
    let steps: UInt16
    /// Units, or units an hour
    let units: Double
    let unit: String
    /// A temp basal's minutes
    let minutes: UInt16?
    var result: String
}

/// The doses the patch was sent, as the simulator lists them, and the limits it refuses a dose past
extension MedtrumKitPumpManager {
    /// The largest bolus the patch takes: 30 U, in steps - the drivers' table (MedtrumKit's `supportedBolusVolumes`,
    /// AndroidAPS's `MEDTRUM_NANO`)
    static let maximumBolusSteps: UInt16 = 600

    /// The highest temp basal rate the patch takes, in steps: 25 U/h on a 200U base, 30 U/h on a 300U one - the drivers'
    /// tables (MedtrumKit's `supportedBasalRates`; AndroidAPS has 25 U/h for both)
    var maximumTempBasalSteps: UInt16 {
        currentModel.index == 0 ? 500 : 600
    }

    private static let receivedDosesKept = 50

    /// A dose command arrived, `result` what the patch did with it - logged, and listed. On the queue.
    func noteReceivedDose(
        _ command: String,
        steps: UInt16,
        unit: String,
        minutes: UInt16? = nil,
        result: String
    ) {
        let dose = ReceivedDose(
            at: .now,
            command: command,
            steps: steps,
            units: Double(steps) * 0.05,
            unit: unit,
            minutes: minutes,
            result: result
        )
        receivedDoses.append(dose)
        if receivedDoses.count > Self.receivedDosesKept {
            receivedDoses.removeFirst(receivedDoses.count - Self.receivedDosesKept)
        }

        let amount = String(format: "%.2f", dose.units)
        logger.info(
            "Received \(command): \(steps) steps (0x\(String(format: "%04X", steps))) = \(amount) \(unit)" +
                (minutes.map { " for \($0) min" } ?? "") + " - \(result)"
        )
    }

    /// The doses received, newest first - as of the last state update (`Snapshot`)
    func receivedDoseList() -> PumpManagerList {
        PumpManagerList(
            title: "Doses received",
            columns: ["Time", "Command", "Steps", "Amount", "Result"],
            emptyText: "No SetBolus or SetTempBasal yet. The patch takes 0.05 U steps: a driver floors or rounds " +
                "what the app asked for into them, and this shows what arrived."
        ) { [weak self] in
            self?.snapshot.receivedDoseRows ?? []
        }
    }

    /// The rows of `receivedDoseList`, built on the queue
    func receivedDoseRows() -> [[String]] {
        receivedDoses.reversed().map { dose in
            [
                Self.timeFormatter.string(from: dose.at),
                dose.command,
                "\(dose.steps) (0x\(String(format: "%04X", dose.steps)))",
                "\(String(format: "%.2f", dose.units)) \(dose.unit)" + (dose.minutes.map { ", \($0) min" } ?? ""),
                dose.result,
            ]
        }
    }
}
