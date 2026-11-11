import CoreBluetooth
import Foundation

/// Command faults (`MedtrumKitCommandFaults`) as the link applies them: the command executed or not, its answer
/// dropped, held back, or the link going silent right after it.
///
/// A fault for an executed command applies only once the patch answers it with success: a command the patch rejects
/// (`invalidState`) is answered as usual, and a fault for the next command only stays armed for the one after.
extension MedtrumKitBluetoothManager {
    /// The fault armed for the command being executed
    struct PendingCommandFault {
        let command: UInt8
        let fault: CommandFault
        /// The patch answered the command with success, and the fault took the answer
        var applied = false
        /// Answered late: the answer, then the statuses the command pushed, sent together when it is due
        var late: LateWrites?
        /// Taking the answer for a halt armed on the command (`armHalt`), not a fault of `MedtrumKitCommandFaults`:
        /// nothing there is used up by it
        var forHalt = false
    }

    /// What an answer held back late sends when it is due, in order
    final class LateWrites {
        var writes: [(messages: [Data], params: WriteResponseParam)] = []
    }

    /// The fault for a command that just came in, if it is not to be executed at all - used up, logged
    func takeNotExecutedFault(for command: UInt8) -> Bool {
        guard let fault = pumpManagerDelegate?.commandFaults.armed(for: command), fault.mode == .notExecuted else {
            return false
        }

        let name = MedtrumKitCommandFaults.name(of: command)
        logger.warning("[FAULT] \(name) not executed and not answered (\(fault.description))")
        if pumpManagerDelegate?.patchFaults.current.haltCommand == command {
            logger.warning("[FAULT] \(name) never reached the patch: the halt armed on it stays armed")
        }
        markUsed(fault, for: command)
        return true
    }

    /// Before a command is executed: the fault armed for it, applied to its answer (`holdBackAnswer`)
    func armFault(for command: UInt8) {
        commandFault = pumpManagerDelegate?.commandFaults.armed(for: command).map {
            PendingCommandFault(command: command, fault: $0)
        }
    }

    /// The command had nothing to do - a cancel with nothing running: answered as usual, a fault for the next command
    /// only is not used up by it
    func skipFault(_ why: String) {
        guard let pending = commandFault, pending.fault.once else {
            return
        }

        commandFault = nil
        let name = MedtrumKitCommandFaults.name(of: pending.command)
        logger.warning("[FAULT] \(name): \(why), answered as usual: \(pending.fault.description) not applied, still armed")
    }

    /// After a command was executed: a fault applied to it is used up if it was for one command only
    func finishCommandFault() {
        guard let pending = commandFault else {
            return
        }

        commandFault = nil
        if pending.applied, !pending.forHalt {
            markUsed(pending.fault, for: pending.command)
        }
    }

    private func markUsed(_ fault: CommandFault, for command: UInt8) {
        // A fault armed for one command only is back to normal: the UI follows
        if pumpManagerDelegate?.commandFaults.use(fault, for: command) == true {
            pumpManagerDelegate?.notifyStateDidUpdate()
        }
    }

    /// Whether the answer `messages` is not to go out now: dropped, or sent later
    func holdBackAnswer(_ messages: [Data], status: ResponseStatus, _ params: WriteResponseParam) -> Bool {
        guard var pending = commandFault, params.responseCode == pending.command else {
            return false
        }

        let fault = pending.fault
        let name = MedtrumKitCommandFaults.name(of: pending.command)
        let answer = messages.map { $0.hexString() }.joined(separator: " ")

        guard status == .ok else {
            commandFault = nil
            // A halt's: `haltAfter` tells
            if pending.forHalt {
                return false
            }
            logger.warning(
                "[FAULT] \(name) rejected by the patch (\(status)), answered as usual: \(fault.description) not applied" +
                    (fault.once ? ", still armed" : "")
            )
            return false
        }

        pending.applied = true
        commandFault = pending

        switch fault.mode {
        case .executedNoAnswer:
            logger.warning("[FAULT] \(name) executed, its answer dropped: \(answer)")
            return true

        case .executedLateAnswer:
            logger.warning("[FAULT] \(name) executed, its answer held back for \(Int(fault.seconds)) s: \(answer)")
            let late = LateWrites()
            late.writes.append((messages, params))
            commandFault?.late = late

            let heldInSession = session
            let heldInGeneration = pumpManagerDelegate?.patchFaults.generation
            pumpBluetoothManager.managerQueue.asyncAfter(deadline: .now() + fault.seconds) { [weak self] in
                guard let self else {
                    return
                }

                guard session == heldInSession else {
                    logger.warning("[FAULT] late answer dropped: \(name)'s, the session it was held back in is over")
                    return
                }

                guard pumpManagerDelegate?.patchFaults.generation == heldInGeneration else {
                    logger.warning("[FAULT] late answer dropped: \(name)'s, the faults were disarmed since")
                    return
                }

                guard !isLinkSilent else {
                    logger.warning("[FAULT] \(name): the late answer is lost, the link is silent")
                    return
                }

                let statuses = late.writes.count - 1
                logger.warning(
                    "[FAULT] \(name): sending the late answer" +
                        (statuses > 0 ? ", then the status(es) it pushed: \(statuses)" : "")
                )
                for write in late.writes {
                    enqueue(write.messages, write.params)
                }
            }
            return true

        case .executedThenLinkSilent:
            logger.warning("[FAULT] \(name) executed, its answer lost: \(answer)")
            silenceLink(for: fault.seconds)
            return true

        case .normal,
             .notExecuted:
            return false
        }
    }

    /// Whether a status the command being executed pushes is not to go out now: its answer was taken by a fault, and
    /// the status announcing the change goes with it - lost, or sent right after the late answer. After a lost one,
    /// the next status after the fault tells the patch's state.
    func holdBackStatus(_ data: Data, _ params: WriteResponseParam) -> Bool {
        guard let pending = commandFault, pending.applied else {
            return false
        }

        let name = MedtrumKitCommandFaults.name(of: pending.command)
        if let late = pending.late {
            late.writes.append(([data], params))
            logger.warning("[FAULT] \(name): the status it pushed is held back with its answer: \(data.hexString())")
        } else {
            logger.warning("[FAULT] \(name): the status it pushed is lost with its answer: \(data.hexString())")
        }
        return true
    }

    /// A halt armed on a command that just came in, if any: if its answer is to be lost with it, the command gets a
    /// fault taking the answer (and any status it pushes) in place of one armed for it
    func armHalt(for command: UInt8) -> PatchFaultSettings? {
        guard let settings = pumpManagerDelegate?.patchFaults.current, settings.haltCommand == command else {
            return nil
        }

        // One that drops the command never gets here (`takeNotExecutedFault`)
        if let fault = pumpManagerDelegate?.commandFaults.armed(for: command) {
            logger.warning(
                "[FAULT] \(MedtrumKitCommandFaults.name(of: command)): the halt armed on it takes its place, " +
                    "\(fault.mode.title) is not applied and stays armed"
            )
        }

        if settings.haltLosesAnswer {
            commandFault = PendingCommandFault(
                command: command,
                fault: CommandFault(mode: .executedNoAnswer, once: true),
                forHalt: true
            )
        }
        return settings
    }

    /// The command was executed: the patch halts if it answered it with success - the halt's status going out, the
    /// answer before it or lost. A command it rejected leaves the halt armed.
    func haltAfter(_ command: UInt8, _ settings: PatchFaultSettings) {
        let name = MedtrumKitCommandFaults.name(of: command)
        guard let lastAnswer, lastAnswer.command == command, lastAnswer.status == .ok else {
            logger.warning("[FAULT] \(name) not executed with success: the halt armed on it stays armed")
            return
        }

        logger.warning(
            "[FAULT] The patch halts (\(settings.haltKind.title)) as it executes \(name)" +
                (settings.haltLosesAnswer ? ", its answer lost" : ", right after its answer")
        )
        // Used up only by a halt that happened
        if pumpManagerDelegate?.haltNow(settings.haltKind) == true {
            pumpManagerDelegate?.patchFaults.update { $0.haltCommand = nil }
            pumpManagerDelegate?.notifyStateDidUpdate()
        } else {
            logger.warning("[FAULT] \(name): the patch did not halt, the halt armed on it stays armed")
        }
    }

    /// A silent link speaks again now
    func endSilence() {
        guard linkSilentUntil != nil else {
            return
        }

        linkSilentUntil = nil
        logger.warning("[FAULT] Link no longer silent: the next status tells the patch's state")
        pumpManagerDelegate?.notifyStateDidUpdate()
    }

    /// The link goes silent for `seconds`: nothing is sent - answers, statuses - and what the phone sends is lost. The
    /// patch goes on delivering. A Mac can't disconnect a central from the peripheral side, so the phone stays
    /// connected: it sees its commands time out and no status come. A real disconnect is the Mac's Bluetooth turned
    /// off, or the phone taken out of range.
    func silenceLink(for seconds: Double) {
        let until = Date.now.addingTimeInterval(seconds)
        linkSilentUntil = until
        writeQueue.removeAll()
        buffer = Data()

        logger.warning(
            "[FAULT] Link silent for \(Int(seconds)) s: nothing is sent, what the phone sends is lost. The phone stays connected."
        )
        pumpManagerDelegate?.notifyStateDidUpdate()

        pumpBluetoothManager.managerQueue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, linkSilentUntil == until else {
                return
            }

            linkSilentUntil = nil
            logger.warning("[FAULT] Link no longer silent: the next status tells the patch's state")
            pumpManagerDelegate?.notifyStateDidUpdate()
        }
    }
}
