import Foundation
import SwiftUI

/// The patch simulated. Every change to its state and record log - commands, timers, the UI's actions - runs on one
/// serial queue, `queue` (the Bluetooth one); the UI only reads.
public class MedtrumKitPumpManager: PumpManagerProtocol {
    public static let identifier: String = "medtrumkit"
    public var title: String = "MedtrumKit"

    public var capabilities = PumpManagerCapabitilties(
        supportedModels: [
            PumpModel(name: "200U", image: Image(imageName: "nano200"), index: 0),
            PumpModel(name: "300U", image: Image(imageName: "nano300"), index: 1),
        ],
        canExpire: true,
        actions: []
    )

    public var currentModel: PumpModel {
        get {
            capabilities.supportedModels.first(where: { $0.index == state.currentModelIndex }) ?? capabilities.supportedModels[0]
        }
        set {
            queue.async {
                self.state.currentModelIndex = newValue.index
                self.notifyStateDidUpdate()
            }
        }
    }

    public var pumpState: String {
        state.patchState.title
    }

    public var pumpNotes: String {
        "Pump base serial number: \(currentModel.index == 0 ? "4A12D828" : "52DF1614")\n" +
            "Patch id: \(state.patchId), newest record: #\(state.recordLog.newestWritten)"
    }

    public var expiresAt: Date? {
        state.expiresAt
    }

    public var activatedAt: Date? {
        state.activatedAt
    }

    public var basal: [BasalItem] {
        get { state.basal }
        set {
            queue.async {
                self.state.basal = newValue
                self.notifyStateDidUpdate()
            }
        }
    }

    public var batteryLevel: String? {
        "\(state.voltageB)V"
    }

    public var reservoirLevel: Double {
        state.reservoirLevel
    }

    /// Read only: what ran out meanwhile is ended by the patch clock (`advanceDelivery`), on the queue
    public var basalState: BasalState {
        if state.patchState == .suspended,
           let suspendedSince = state.suspendedSince,
           let suspendedDuration = state.suspendedDuration
        {
            return .suspended(start: suspendedSince, duration: suspendedDuration)

        } else if let rate = state.tempBasalRate,
                  let start = state.tempBasalStart,
                  let duration = state.tempBasalDuration
        {
            return .tempBasal(rate: rate, start: start, end: start + duration)

        } else {
            return .active(rate: state.currentBaseBasalRate)
        }
    }

    public var bolusProgress: BolusState? {
        guard let progress = state.bolusProgress, let total = state.bolusTotal else {
            return nil
        }

        return BolusState(total: total, progress: progress)
    }

    public var storageDelegate: (any StorageDelegate)?
    public var rawState: StateRawValue {
        state.getRaw()
    }

    let logger = PumpManagerLogger(subsystem: "com.bastiaanv.medtrumkit", category: "MedtrumKitPumpManager")
    let bluetooth: MedtrumKitBluetoothManager
    var state: MedtrumKitState
    var isRunning: Bool = false
    let commandFaults = MedtrumKitCommandFaults()

    /// The queue the patch's state is changed on
    var queue: DispatchQueue {
        bluetooth.pumpBluetoothManager.managerQueue
    }

    /// Ends what ran out - temp basals, suspends, schedule blocks, midnight - while no command or status does
    private var patchClock: DispatchSourceTimer?

    public required init(rawValue: StateRawValue, bluetoothManager: PumpBluetoothmanager) {
        state = MedtrumKitState(rawValue: rawValue)
        bluetooth = MedtrumKitBluetoothManager(pumpBluetoothManager: bluetoothManager)

        capabilities.actions.append(
            PumpManagerActions(
                label: "Trigger Occlussion",
                action: triggerOcclussion
            )
        )

        capabilities.actions.append(
            PumpManagerActions(
                label: "Trigger maxHour suspend",
                action: triggerMaxHourSuspend
            )
        )

        for patchState in [PatchState.none, .idle, .filled] {
            capabilities.actions.append(
                PumpManagerActions(label: "Set patch: \(patchState.title)") { [weak self] in
                    self?.queue.async { self?.setPatchState(patchState) }
                }
            )
        }

        capabilities.sliders.append(
            PumpManagerSlider(
                label: "Fill patch",
                // The 300U patch is the larger of the two models, so the range covers both
                range: 0 ... 300,
                step: 5,
                unit: "U",
                get: { [weak self] in self?.state.reservoirLevel ?? 0 },
                set: { [weak self] level in self?.queue.async { self?.fillPatch(to: level) } }
            )
        )

        // The patch went on delivering while the simulator was closed: the bolus has completed
        if let total = state.bolusTotal, state.bolusStart != nil {
            state.advance(to: .now)
            state.finishBolus(delivered: total, cause: MedtrumKitPackets.bolusCompleted, at: .now)
            logger.info("A bolus of \(total)U was running when the simulator closed, written as delivered in full")
        } else if state.bolusTotal != nil {
            // Saved before records were kept: nothing to write it under, and nothing would ever end it
            state.bolusTotal = nil
            state.bolusProgress = nil
            logger.info("A bolus was running when the simulator closed, from before records were kept: cleared")
        }

        capabilities.controlGroups.append(commandFaultControls())
        capabilities.lists.append(recordList())
        capabilities.lists.append(armedFaultList())

        bluetooth.pumpManagerDelegate = self

        patchClock = MedtrumKitPackets.repeatingTimer(on: queue, every: 5) { [weak self] in
            self?.advanceDelivery()
        }
    }

    deinit {
        patchClock?.cancel()
    }

    public func startAdvertising() {
        queue.async { [self] in
            // Faults armed while stopped stay armed: Start is the natural moment to arm one
            if state.activatedAt == nil {
                state.activatedAt = Date.now
                state.patchState = .filled
                notifyStateDidUpdate()
            }

            bluetooth.startAdvertising()
            isRunning = true
        }
    }

    public func reset() {
        queue.async { [self] in
            MedtrumKitPackets.stopBolusTimer()
            MedtrumKitPackets.stopPrimeTimer()
            state = MedtrumKitState(rawValue: [:])
            // A new pump: nothing from the old one reaches the phone - a silent link, a late answer
            bluetooth.endSession()
            resetCommandFaults()
            notifyStateDidUpdate()
        }
    }

    public func stop() {
        queue.async { [self] in
            guard isRunning else {
                return
            }

            bluetooth.stopAdvertising()
            isRunning = false
            resetCommandFaults()
            notifyStateDidUpdate()

            logger.info("MedtrumKit simulator has been stopped!")
        }
    }

    private static let lastPatchIdKey = "MedtrumKitSimulator.lastPatchId"

    /// The id of the patch to activate: one up on the last one handed out. Kept apart from the state, so a Reset Pump
    /// never hands out an id again - a real base never does.
    func nextPatchId() -> UInt32 {
        let last = max(UInt32(UserDefaults.standard.integer(forKey: Self.lastPatchIdKey)), state.patchId)
        let next = last >= 0xFFFF ? 1 : last + 1
        UserDefaults.standard.set(Int(next), forKey: Self.lastPatchIdKey)
        return next
    }

    /// Saves the state and refreshes the UI - on the queue, the state's writes being there
    func notifyStateDidUpdate() {
        dispatchPrecondition(condition: .onQueue(queue))
        storageDelegate?.saveState(MedtrumKitPumpManager.self, self)
    }

    /// Brings the patch up to now - temp basals and suspends that ran out, midnight - writing the records of what ended
    func advanceDelivery() {
        dispatchPrecondition(condition: .onQueue(queue))
        if state.advance(to: .now) {
            notifyStateDidUpdate()
        }
    }

    private func triggerOcclussion() {
        queue.async { self.halt(.occlusion, reason: .STOP_OCCLUSION) }
    }

    private func triggerMaxHourSuspend() {
        queue.async { self.halt(.hourlyMaxSuspended, reason: .SUSPEND_MORE_THAN_MAX_PER_HOUR) }
    }

    /// The patch stops delivering on its own: a running bolus is cut short, the basal segment ends with `reason`
    private func halt(_ haltState: PatchState, reason: BasalEndReason) {
        advanceDelivery()

        let delivered = MedtrumKitPackets.endBolus(pumpManager: self, cause: MedtrumKitPackets.bolusInterrupted)
        state.halt(haltState, reason: reason, at: .now)
        notifyStateDidUpdate()

        logger.info("Patch halted: \(haltState.title)\(delivered.map { ", bolus cut at \($0)U" } ?? "")")

        MedtrumKitPackets.sendStatusUpdate(
            completedBolus: delivered.map { .init(cause: MedtrumKitPackets.bolusInterrupted, delivered: $0) }
        )
    }

    private static let minimumFill: Double = 70

    private func fillPatch(to level: Double) {
        guard state.patchState.rawValue < PatchState.priming.rawValue else {
            logger.warning("Refusing to fill a patch which is past priming: \(state.patchState)")
            return
        }

        state.reservoirLevel = level

        if level >= Self.minimumFill, state.patchState != .filled {
            state.patchState = .filled
        } else if level < Self.minimumFill, state.patchState == .filled {
            state.patchState = .idle
        }

        notifyStateDidUpdate()

        logger.info("Patch filled to \(level)U, state: \(state.patchState)")

        MedtrumKitPackets.sendStatusUpdate()
    }

    private func setPatchState(_ patchState: PatchState) {
        state.patchState = patchState

        MedtrumKitPackets.stopPrimeTimer()
        state.primeProgress = nil

        notifyStateDidUpdate()

        logger.info("Patch state set to \(patchState)")

        MedtrumKitPackets.sendStatusUpdate()
    }
}
