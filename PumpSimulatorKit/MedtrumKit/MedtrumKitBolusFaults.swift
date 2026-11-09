import Foundation

/// Which boluses a bolus fault is for: off, the next one only - the setting going back to off as a bolus takes it - or
/// every one until changed
enum BolusFaultScope: Int, CaseIterable {
    case off
    case nextBolus
    case everyBolus

    var title: String {
        switch self {
        case .off: "Off"
        case .nextBolus: "Next bolus"
        case .everyBolus: "Every bolus"
        }
    }
}

/// Where a stall starts: at an amount delivered, or at a share of the bolus
enum BolusStallStart: Int, CaseIterable {
    case units
    case fraction

    var title: String {
        switch self {
        case .units: "At units delivered"
        case .fraction: "At a share of the bolus"
        }
    }
}

/// The patch's own occlusion alarm for a stalled bolus
enum BolusStallAlarm: Int, CaseIterable {
    /// Seconds after the bolus completed, as on 2026-10-13 (205 s)
    case afterCompletion
    /// After a number of slow steps, cutting the bolus there
    case duringStall
    /// None: the patch never raises one
    case none

    var title: String {
        switch self {
        case .afterCompletion: "Occlusion after completion"
        case .duringStall: "Occlusion during the stall"
        case .none: "No alarm"
        }
    }
}

/// A bolus that stalls against a blocked cannula, as on 2026-10-13 (MedtrumKit's `ManagerBolusScenarioTests+Stall`): 5 U
/// at the patch's pace up to 3.5 U, then one 0.1 U step every 40, 38, 36, ... s while the patch kept sending its other
/// packets every 8 s, "completed" in full after 529 s, its occlusion alarm 205 s after that.
struct BolusStallSettings {
    var scope: BolusFaultScope = .off
    var start: BolusStallStart = .fraction
    var startUnits: Double = 3.5
    /// Percent of the bolus
    var startPercent: Double = 70
    /// The gap to the first slow step, then each one shorter by `shrink`, never below `minimumInterval`
    var interval: Double = 40
    var shrink: Double = 0
    /// No packet between the slow steps - no notification, no heartbeat - as in 2 of 3 boluses in the logs; otherwise
    /// a notification without the bolus field every `otherPacketsEvery` s
    var stepsOnly = false
    /// Back to the patch's pace after this many slow steps, and on to a normal completion - 0: never
    var resumeAfter = 0
    var alarm: BolusStallAlarm = .afterCompletion
    var alarmDelay: Double = 205
    /// The slow steps after which an alarm during the stall comes
    var alarmAfterSlowSteps = 3

    /// A slow step's amount, as the real patch's
    static let slowStepUnits = 0.1
    static let otherPacketsEvery: TimeInterval = 8
    static let minimumInterval: TimeInterval = 4

    /// The plan for a bolus of `amount`, nil if it ends before the stall would start
    func plan(for amount: Double) -> BolusStallPlan? {
        let from = switch start {
        case .units: startUnits
        case .fraction: amount * startPercent / 100
        }
        // On the patch's steps, at least the first pulse - delivered as the patch answers
        let fromUnits = max(0.05, (from / 0.05 + 1E-9).rounded(.down) * 0.05)
        guard fromUnits < amount - 1E-9 else {
            return nil
        }

        return BolusStallPlan(
            fromUnits: fromUnits,
            interval: interval,
            shrink: shrink,
            stepsOnly: stepsOnly,
            resumeAfter: resumeAfter > 0 ? resumeAfter : nil,
            alarm: alarm,
            alarmDelay: alarmDelay,
            alarmAfterSlowSteps: max(1, alarmAfterSlowSteps)
        )
    }

    var description: String {
        let from = switch start {
        case .units: String(format: "from %.2f U", startUnits)
        case .fraction: "from \(Int(startPercent))% of it"
        }
        var text = "\(from), a 0.1 U step every \(Int(interval)) s"
        if shrink > 0 {
            text += " (\(Int(shrink)) s less each)"
        }
        text += stepsOnly ? ", nothing in between" : ", other packets every \(Int(Self.otherPacketsEvery)) s"
        if resumeAfter > 0 {
            text += ", the patch's pace again after \(resumeAfter) slow steps"
        }
        switch alarm {
        case .afterCompletion: text += ", occlusion \(Int(alarmDelay)) s after its completion"
        case .duringStall: text += ", occlusion after \(max(1, alarmAfterSlowSteps)) slow steps"
        case .none: text += ", no alarm"
        }
        return text
    }
}

/// What a stall does to the one bolus that took it - see `BolusStallSettings`
struct BolusStallPlan {
    /// The last step at the patch's pace: the slow steps come after it
    let fromUnits: Double
    let interval: Double
    let shrink: Double
    let stepsOnly: Bool
    let resumeAfter: Int?
    let alarm: BolusStallAlarm
    let alarmDelay: Double
    let alarmAfterSlowSteps: Int
}

/// The patch raises its occlusion alarm some minutes after a bolus completed in full - with no stall before it
struct DelayedOcclusionSettings {
    var scope: BolusFaultScope = .off
    var minutes: Double = 3

    var description: String {
        "occlusion \(String(format: "%g", minutes)) min after it completes in full"
    }
}
