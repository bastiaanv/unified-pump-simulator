import Foundation

/// What the simulator does with a command instead of executing and answering it at once
enum CommandFaultMode: Int, CaseIterable {
    case normal
    /// Executed, the answer never sent
    case executedNoAnswer
    /// Executed, the answer sent `CommandFault.seconds` later
    case executedLateAnswer
    /// Neither executed nor answered, as if it never arrived
    case notExecuted
    /// Executed, then the link goes silent for `CommandFault.seconds`: the answer and everything else the patch would
    /// send is lost, and what the phone sends meanwhile never arrives. The phone stays connected - a Mac can't drop
    /// the link from the peripheral side.
    case executedThenLinkSilent

    var title: String {
        switch self {
        case .normal: "Normal"
        case .executedNoAnswer: "Executed, no answer"
        case .executedLateAnswer: "Executed, answered late"
        case .notExecuted: "Not executed, no answer"
        case .executedThenLinkSilent: "Executed, then the link goes silent"
        }
    }
}

struct CommandFault {
    var mode: CommandFaultMode = .normal
    /// Applied to the next such command only, then back to normal - or to every one until changed
    var once = true
    /// How late the answer comes, or how long the link stays silent
    var seconds: Double = 10

    var description: String {
        var text = mode.title
        if mode == .executedLateAnswer {
            text += " by \(Int(seconds)) s"
        } else if mode == .executedThenLinkSilent {
            text += " for \(Int(seconds)) s"
        }
        return text + (once ? ", next one only" : ", until changed")
    }
}

/// The faults armed per command. Read on the Bluetooth queue as commands come in, changed from the UI. They are not
/// saved, and are back to normal at Stop and Reset Pump.
final class MedtrumKitCommandFaults {
    static let commands: [(command: UInt8, name: String)] = [
        (CommandType.SET_BOLUS, "SetBolus"),
        (CommandType.CANCEL_BOLUS, "CancelBolus"),
        (CommandType.SET_TEMP_BASAL, "SetTempBasal"),
        (CommandType.CANCEL_TEMP_BASAL, "CancelTempBasal"),
        (CommandType.SUSPEND_PUMP, "Suspend"),
        (CommandType.RESUME_PUMP, "Resume"),
        (CommandType.GET_RECORD, "GetRecord"),
        (CommandType.STOP_PATCH, "StopPatch"),
        (CommandType.SYNCHRONIZE, "Synchronize"),
    ]

    static func name(of command: UInt8) -> String {
        commands.first { $0.command == command }?.name ?? "command \(command)"
    }

    private let lock = NSLock()
    private var faults: [UInt8: CommandFault] = [:]

    func fault(for command: UInt8) -> CommandFault {
        lock.withLock { faults[command] ?? CommandFault() }
    }

    func update(_ command: UInt8, _ change: (inout CommandFault) -> Void) {
        lock.withLock {
            var fault = faults[command] ?? CommandFault()
            change(&fault)
            faults[command] = fault
        }
    }

    /// The fault armed for a command that just came in, if any - not used up yet: see `use`
    func armed(for command: UInt8) -> CommandFault? {
        lock.withLock {
            guard let fault = faults[command], fault.mode != .normal else {
                return nil
            }
            return fault
        }
    }

    /// `fault` was applied to a command: back to normal if it was for one command only. Whether it was.
    @discardableResult func use(_ fault: CommandFault, for command: UInt8) -> Bool {
        lock.withLock {
            guard fault.once, faults[command]?.mode == fault.mode else {
                return false
            }

            faults[command]?.mode = .normal
            return true
        }
    }

    /// Every command back to normal - how late and whether once are kept for the next time
    func reset() {
        lock.withLock {
            for command in faults.keys {
                faults[command]?.mode = .normal
            }
        }
    }

    var armed: [(name: String, fault: CommandFault)] {
        lock.withLock {
            Self.commands.compactMap { command in
                faults[command.command].flatMap { $0.mode == .normal ? nil : (command.name, $0) }
            }
        }
    }
}
