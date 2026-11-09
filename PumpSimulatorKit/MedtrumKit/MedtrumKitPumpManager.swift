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

    /// What the UI reads, as of the last state update: built on the queue (`refreshSnapshot`), read from the main
    /// thread
    struct Snapshot {
        var pumpState = ""
        var pumpNotes = ""
        var reservoir: Double = 0
        var isFillable = false
        var basalState = BasalState.active(rate: 0)
        var bolusProgress: BolusState?
        var activatedAt: Date?
        var expiresAt: Date?
        var batteryLevel: String?
        var recordRows: [[String]] = []
        var stoppedPatchUntil: Date?
        var linkSilentUntil: Date?
        /// What the running bolus does beyond the patch's pace (`BolusRun`)
        var runningBolusFault: String?
        var receivedDoseRows: [[String]] = []
    }

    private let snapshotLock = NSLock()
    private var _snapshot = Snapshot()
    var snapshot: Snapshot {
        snapshotLock.withLock { _snapshot }
    }

    public var pumpState: String {
        snapshot.pumpState
    }

    public var pumpNotes: String {
        snapshot.pumpNotes
    }

    public var expiresAt: Date? {
        snapshot.expiresAt
    }

    public var activatedAt: Date? {
        snapshot.activatedAt
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
        snapshot.batteryLevel
    }

    /// What is left: the running segment and bolus taken off
    public var reservoirLevel: Double {
        snapshot.reservoir
    }

    /// Read only: what ran out meanwhile is ended by the patch clock (`advanceDelivery`), on the queue
    public var basalState: BasalState {
        snapshot.basalState
    }

    public var bolusProgress: BolusState? {
        snapshot.bolusProgress
    }

    /// The UI's copy of the state, on the queue
    private func refreshSnapshot() {
        let basalState: BasalState = if state.patchState == .suspended,
                                        let suspendedSince = state.suspendedSince,
                                        let suspendedDuration = state.suspendedDuration
        {
            .suspended(start: suspendedSince, duration: suspendedDuration)
        } else if let rate = state.tempBasalRate, let start = state.tempBasalStart, let duration = state.tempBasalDuration {
            .tempBasal(rate: rate, start: start, end: start + duration)
        } else {
            .active(rate: state.currentBaseBasalRate)
        }

        let snapshot = Snapshot(
            pumpState: state.patchState.title,
            pumpNotes: "Pump base serial number: \(currentModel.index == 0 ? "4A12D828" : "52DF1614")\n" +
                "Patch id: \(state.patchId), newest record: #\(state.recordLog.newestWritten)",
            reservoir: state.insulinLeft(),
            isFillable: state.isFillable,
            basalState: basalState,
            bolusProgress: state.bolusProgress.flatMap { progress in
                state.bolusTotal.map { BolusState(total: $0, progress: progress) }
            },
            activatedAt: state.activatedAt,
            expiresAt: state.expiresAt,
            batteryLevel: "\(state.voltageB)V",
            recordRows: recordRows(),
            stoppedPatchUntil: state.stoppedPatchUntil,
            linkSilentUntil: bluetooth.linkSilentUntil,
            runningBolusFault: MedtrumKitPackets.bolusRun?.faultDescription,
            receivedDoseRows: receivedDoseRows()
        )
        snapshotLock.withLock { _snapshot = snapshot }
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
    let patchFaults = MedtrumKitPatchFaults()
    /// The newest SetBolus and SetTempBasal commands received, and what the patch did with them - on the queue, not
    /// saved
    var receivedDoses: [ReceivedDose] = []

    /// The queue the patch's state is changed on
    var queue: DispatchQueue {
        bluetooth.pumpBluetoothManager.managerQueue
    }

    /// Ends what ran out - temp basals, suspends, schedule blocks, midnight - while no command or status does
    private var patchClock: DispatchSourceTimer?

    public required init(rawValue: StateRawValue, bluetoothManager: PumpBluetoothmanager) {
        state = MedtrumKitState(rawValue: rawValue)
        bluetooth = MedtrumKitBluetoothManager(pumpBluetoothManager: bluetoothManager)

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
                note: "Only while filling, before priming - as on a real patch. Then delivery drains it.",
                isEnabled: { [weak self] in self?.snapshot.isFillable ?? false },
                get: { [weak self] in self?.snapshot.reservoir ?? 0 },
                set: { [weak self] level in self?.queue.async { self?.fillPatch(to: level) } }
            )
        )

        // The patch went on delivering while the simulator was closed: the bolus has completed
        if let total = state.bolusTotal, let start = state.bolusStart {
            state.advance(to: .now)
            // In full, unless what was left could not hold it: then it ran dry, the bolus cut at what was left. Not if
            // it ended meanwhile: the patch halted.
            let available = state.insulinForBolus(at: .now)
            if !state.isBolusRunning || state.bolusStart != start {
                logger.info("A bolus of \(total)U was running when the simulator closed, ended by a halt meanwhile")
            } else if available < total, state.isDeliveringBasal {
                state.bolusProgress = available
                state.runDry(at: .now)
                logger.info("A bolus of \(total)U was running when the simulator closed: the patch ran dry at \(available)U")
            } else {
                state.finishBolus(delivered: total, cause: MedtrumKitPackets.bolusCompleted, at: .now)
                logger.info("A bolus of \(total)U was running when the simulator closed, written as delivered in full")
            }
        } else if state.bolusTotal != nil {
            // Saved before records were kept: nothing to write it under, and nothing would ever end it
            state.bolusTotal = nil
            state.bolusProgress = nil
            logger.info("A bolus was running when the simulator closed, from before records were kept: cleared")
        }

        capabilities.controlGroups.append(scenarioControls())
        capabilities.controlGroups.append(commandFaultControls())
        capabilities.controlGroups.append(patchFaultControls())
        capabilities.controlGroups.append(bolusFaultControls())
        capabilities.lists.append(armedFaultList())
        capabilities.lists.append(recordList())
        capabilities.lists.append(receivedDoseList())

        bluetooth.pumpManagerDelegate = self
        refreshSnapshot()

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
            if state.isFillable, state.patchState != .filled {
                logger.info(
                    "No patch filled yet (\(state.reservoirLevel)U): fill it - at least \(Self.minimumFill)U - before priming"
                )
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
            resetPatchFaults()
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
            resetPatchFaults()
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
        refreshSnapshot()
        storageDelegate?.saveState(MedtrumKitPumpManager.self, self)
    }

    /// Brings the patch up to now - temp basals and suspends that ran out, midnight, running dry - writing the records
    /// of what ended, and telling the phone of a halt
    func advanceDelivery() {
        dispatchPrecondition(condition: .onQueue(queue))
        if let until = state.stoppedPatchUntil, until <= .now {
            logger.info("The stopped patch no longer answers: the base is on a new patch")
            putNewPatch(announce: true)
        }

        if state.advance(to: .now) {
            notifyStateDidUpdate()
        } else {
            // What is left goes down as the patch delivers, with no record written
            refreshSnapshot()
        }
        deliverHaltNotice()
    }

    /// A halt the patch came to on its own - running dry - is told the phone: a status, carrying the completion of a
    /// bolus it cut
    private func deliverHaltNotice() {
        guard let notice = state.haltNotice else {
            return
        }

        state.haltNotice = nil
        MedtrumKitPackets.stopBolusTimer()
        notifyStateDidUpdate()
        logger.warning("Patch ran dry\(notice.cutBolus.map { ", bolus cut at \($0)U" } ?? "")")
        MedtrumKitPackets.sendStatusUpdate(
            completedBolus: notice.cutBolus.map { .init(cause: MedtrumKitPackets.bolusInterrupted, delivered: $0) },
            haltNotification: true
        )
    }

    /// The patch runs dry now - what is left goes, a running bolus is cut at what it delivered. Whether it did: not if
    /// it was not delivering.
    @discardableResult func runDry() -> Bool {
        advanceDelivery()
        // Ran dry meanwhile, as it caught up
        if state.patchState == .reservoirEmpty {
            return true
        }
        guard state.isDeliveringBasal else {
            logger.warning("Not running dry: the patch is not delivering (\(state.patchState.title))")
            return false
        }

        state.runDry(at: .now)
        deliverHaltNotice()
        return true
    }

    /// The patch halts now, as `kind`. Whether it did: not if it was not running.
    @discardableResult func haltNow(_ kind: HaltKind) -> Bool {
        switch kind {
        case .occlusion:
            halt(.occlusion, reason: .STOP_OCCLUSION)
        case .hourlyMaxSuspended:
            halt(.hourlyMaxSuspended, reason: .SUSPEND_MORE_THAN_MAX_PER_HOUR)
        case .reservoirEmpty:
            runDry()
        }
    }

    /// The base restarts: the patch's session is lost - delivery stops with nothing more written, a running bolus with
    /// it - and the base reports state none with the next patch's id and its age (`baseResetAt`). Fill a new patch to
    /// go on: it is activated under that id.
    func baseReset() {
        MedtrumKitPackets.stopBolusTimer()
        MedtrumKitPackets.stopPrimeTimer()
        state.clearDelivery()
        // A restarted base holds nothing back for the phone - a late answer - and its link is not silent
        bluetooth.endSession()

        state.patchId = nextPatchId()
        state.updateRecordLog { $0.reset() }
        state.patchState = .none
        state.reservoirLevel = 0
        state.baseResetAt = .now
        callOffPendingOcclusion("the base restarted")
        notifyStateDidUpdate()

        logger.warning("[FAULT] The base restarted: state none, next patch id \(state.patchId), no session")
        MedtrumKitPackets.sendStatusUpdate()
    }

    /// The reservoir of the model chosen
    var capacity: Double {
        currentModel.index == 0 ? 200 : 300
    }

    /// The base is on a new patch, filled and ready to prime: after a StopPatch, or the old one gone without one. The
    /// old patch's records stay readable until the new one activates. `announce`: a status tells the phone.
    func putNewPatch(announce: Bool = false) {
        MedtrumKitPackets.stopBolusTimer()
        MedtrumKitPackets.stopPrimeTimer()
        state.clearDelivery()
        state.patchState = .filled
        state.reservoirLevel = capacity
        // A record fault that stuck to a record of the old patch
        patchFaults.update { $0.recordFaultNumber = nil }
        callOffPendingOcclusion("the base is on a new patch")
        notifyStateDidUpdate()
        if announce {
            MedtrumKitPackets.sendStatusUpdate()
        }
    }

    /// The patch stops delivering on its own: a running bolus is cut short, the basal segment ends with `reason`.
    /// Whether it did: not if it was not running.
    private func halt(_ haltState: PatchState, reason: BasalEndReason) -> Bool {
        advanceDelivery()
        guard state.isPatchRunning else {
            logger.warning("Not halting: the patch is not running (\(state.patchState.title))")
            return false
        }

        let delivered = MedtrumKitPackets.endBolus(pumpManager: self, cause: MedtrumKitPackets.bolusInterrupted)
        state.halt(haltState, reason: reason, at: .now)
        notifyStateDidUpdate()

        logger.info("Patch halted: \(haltState.title)\(delivered.map { ", bolus cut at \($0)U" } ?? "")")

        MedtrumKitPackets.sendStatusUpdate(
            completedBolus: delivered.map { .init(cause: MedtrumKitPackets.bolusInterrupted, delivered: $0) }
        )
        return true
    }

    static let minimumFill: Double = 70

    private func fillPatch(to level: Double) {
        guard state.isFillable else {
            logger.warning("Refusing to fill a patch which is past priming: \(state.patchState)")
            notifyStateDidUpdate()
            return
        }

        let level = min(level, capacity)
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
