import Foundation
import SwiftUI

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
            state.currentModelIndex = newValue.index
        }
    }

    public var pumpState: String {
        state.patchState.title
    }

    public var pumpNotes: String {
        "Pump base serial number: \(currentModel.index == 0 ? "4A12D828" : "52DF1614")"
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
            state.basal = newValue
            notifyStateDidUpdate()
        }
    }

    public var batteryLevel: String? {
        "\(state.voltageB)V"
    }

    public var reservoirLevel: Double {
        state.reservoirLevel
    }

    public var basalState: BasalState {
        if state.patchState == .suspended,
           let suspendedSince = state.suspendedSince,
           let suspendedDuration = state.suspendedDuration
        {
            if suspendedSince.addingTimeInterval(suspendedDuration) < Date.now {
                state.suspendedSince = nil
                state.suspendedDuration = nil
                state.patchState = .active
                notifyStateDidUpdate()

                return .active(rate: state.currentBaseBasalRate)
            }

            return .suspended(start: suspendedSince, duration: suspendedDuration)

        } else if let rate = state.tempBasalRate,
                  let start = state.tempBasalStart,
                  let duration = state.tempBasalDuration
        {
            if start.addingTimeInterval(duration) < Date.now {
                state.tempBasalRate = nil
                state.tempBasalStart = nil
                state.tempBasalDuration = nil
                notifyStateDidUpdate()

                return .active(rate: state.currentBaseBasalRate)
            }

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

    private let logger = PumpManagerLogger(subsystem: "com.bastiaanv.medtrumkit", category: "MedtrumKitPumpManager")
    private let bluetooth: MedtrumKitBluetoothManager
    var state: MedtrumKitState
    var isRunning: Bool = false

    public required init(rawValue: StateRawValue, bluetoothManager: PumpBluetoothmanager) {
        state = MedtrumKitState(rawValue: rawValue)
        bluetooth = MedtrumKitBluetoothManager(pumpBluetoothManager: bluetoothManager)

        capabilities.actions.append(
            PumpManagerActions(
                label: "Trigger Occlussion",
                action: triggerOcclussion
            )
        )

        for patchState in [PatchState.none, .idle, .filled] {
            capabilities.actions.append(
                PumpManagerActions(label: "Set patch: \(patchState.title)") { [weak self] in
                    self?.setPatchState(patchState)
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
                set: { [weak self] in self?.fillPatch(to: $0) }
            )
        )

        bluetooth.pumpManagerDelegate = self
    }

    public func startAdvertising() {
        if state.activatedAt == nil {
            state.activatedAt = Date.now
            state.patchState = .filled
            notifyStateDidUpdate()
        }

        bluetooth.startAdvertising()
        isRunning = true
    }

    public func reset() {
        state = MedtrumKitState(rawValue: [:])
        notifyStateDidUpdate()
    }

    public func stop() {
        guard isRunning else {
            return
        }

        bluetooth.stopAdvertising()
        isRunning = false

        logger.info("MedtrumKit simulator has been stopped!")
    }

    func notifyStateDidUpdate() {
        storageDelegate?.saveState(MedtrumKitPumpManager.self, self)
    }

    private func triggerOcclussion() {
        state.patchState = .occlusion
        notifyStateDidUpdate()

        MedtrumKitPackets.synchronizeTimer?.fire()
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

        MedtrumKitPackets.synchronizeTimer?.fire()
    }

    private func setPatchState(_ patchState: PatchState) {
        state.patchState = patchState

        MedtrumKitPackets.primeTimer?.invalidate()
        MedtrumKitPackets.primeTimer = nil
        state.primeProgress = nil

        notifyStateDidUpdate()

        logger.info("Patch state set to \(patchState)")

        MedtrumKitPackets.synchronizeTimer?.fire()
    }
}
