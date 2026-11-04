import Foundation

/// The command faults, as the simulator lets you arm them and lists the armed ones
extension MedtrumKitPumpManager {
    func commandFaultControls() -> PumpManagerControlGroup {
        let rows = MedtrumKitCommandFaults.commands.map { command in
            PumpManagerControlRow(
                label: command.name,
                controls: [
                    .picker(
                        "Fault",
                        options: CommandFaultMode.allCases.map(\.title),
                        get: { [weak self] in self?.commandFaults.fault(for: command.command).mode.rawValue ?? 0 },
                        set: { [weak self] index in
                            self?.updateFault(command.command) { $0.mode = CommandFaultMode(rawValue: index) ?? .normal }
                        }
                    ),
                    .toggle(
                        "Next one only",
                        get: { [weak self] in self?.commandFaults.fault(for: command.command).once ?? true },
                        set: { [weak self] once in self?.updateFault(command.command) { $0.once = once } }
                    ),
                    .number(
                        "Seconds late / silent",
                        range: 1 ... 120,
                        unit: " s",
                        get: { [weak self] in self?.commandFaults.fault(for: command.command).seconds ?? 10 },
                        set: { [weak self] seconds in self?.updateFault(command.command) { $0.seconds = seconds } }
                    ),
                ]
            )
        }

        return PumpManagerControlGroup(
            title: "Command faults",
            rows: rows,
            footnote: """
            A fault applies to a command the patch executes and answers with success; one it rejects is answered as \
            usual and leaves the fault armed. A cancel with nothing to cancel leaves a "next one only" fault armed \
            too. A status the command pushes goes with its answer: lost, or sent right after the late answer. \
            "Executed, then the link goes silent": for the seconds set, nothing is sent and whatever the phone sends \
            is lost - the phone stays connected, as a Mac can't drop a connection from the peripheral side. To test a \
            real disconnect, take the phone out of range, or turn the Mac's Bluetooth off. Faults are back to normal \
            at Stop and Reset Pump.
            """
        )
    }

    /// Every command back to normal, the UI following
    func resetCommandFaults() {
        guard !commandFaults.armed.isEmpty else {
            return
        }

        commandFaults.reset()
        logger.info("Command faults reset: every command runs normally")
        notifyStateDidUpdate()
    }

    /// From the UI: the faults change at once (they are behind a lock), the save and the UI's refresh on the queue
    private func updateFault(_ command: UInt8, _ change: (inout CommandFault) -> Void) {
        commandFaults.update(command, change)

        let fault = commandFaults.fault(for: command)
        queue.async { [self] in
            logger.info("Fault for \(MedtrumKitCommandFaults.name(of: command)) set: \(fault.description)")
            notifyStateDidUpdate()
        }
    }

    /// The command and patch faults armed, and what they hold now - a silent link, a stopped patch still answering
    func armedFaultList() -> PumpManagerList {
        PumpManagerList(
            title: "Armed faults",
            columns: ["Where", "Fault"],
            emptyText: "None: every command runs normally, the patch too"
        ) { [weak self] in
            guard let self else {
                return []
            }

            let snapshot = snapshot
            var rows = commandFaults.armed.map { [$0.name, $0.description] } + patchFaults.armed
            if let until = snapshot.linkSilentUntil {
                rows.insert(["Link", "silent until \(Self.timeFormatter.string(from: until))"], at: 0)
            }
            if let until = snapshot.stoppedPatchUntil {
                rows.insert(["Patch", "stopped, answering until \(Self.timeFormatter.string(from: until))"], at: 0)
            }
            return rows
        }
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
