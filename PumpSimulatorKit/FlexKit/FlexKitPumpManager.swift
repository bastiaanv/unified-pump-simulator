import Foundation
import SwiftUI

public class MiniMedKitPumpManager: PumpManagerProtocol {
    public static let identifier: String = "minimedflex"
    public var title: String = "MiniMed Flex"

    public var capabilities = PumpManagerCapabitilties(
        supportedModels: [
            PumpModel(name: "MiniMed Flex", image: Image(imageName: "minimedFlex"), index: 0),
        ],
        canExpire: false, // classic tube pump
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
        if state.suspendedSince != nil {
            return "Suspended"
        }
        if state.tempBasalRate != nil {
            return "Temp Basal"
        }
        if state.bolusTotal != nil {
            return "Delivering Bolus"
        }
        return "Running"
    }

    public var pumpNotes: String {
        "Serial: \(state.serialNumber)\nSecure-link: Tier A (transparent)\nPasskey (label on pump): \(state.passkey)"
    }

    public var expiresAt: Date? {
        nil
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
        "\(Int(state.batteryLevel))%"
    }

    public var reservoirLevel: Double {
        state.reservoirLevel
    }

    public var basalState: BasalState {
        if state.suspendedSince != nil {
            return .suspended(start: state.suspendedSince!, duration: nil)

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

    private let logger = PumpManagerLogger(subsystem: "com.bastiaanv.minimedkit", category: "MiniMedKitPumpManager")
    let bluetooth: MiniMedKitBluetoothManager
    var state: MiniMedKitState
    var isRunning: Bool = false

    public required init(rawValue: StateRawValue, bluetoothManager: PumpBluetoothmanager) {
        state = MiniMedKitState(rawValue: rawValue)
        bluetooth = MiniMedKitBluetoothManager(pumpBluetoothManager: bluetoothManager)
        bluetooth.pumpManagerDelegate = self
    }

    public func startAdvertising() {
        if state.activatedAt == nil {
            state.activatedAt = Date.now
            notifyStateDidUpdate()
        }

        bluetooth.startAdvertising()
        isRunning = true
    }

    public func reset() {
        state = MiniMedKitState(rawValue: [:])
        bluetooth.stopAdvertising()
        isRunning = false
        notifyStateDidUpdate()
    }

    public func stop() {
        guard isRunning else {
            return
        }

        bluetooth.stopAdvertising()
        isRunning = false

        if let bolusTimer = MiniMedKitCommandPackets.bolusTimer {
            bolusTimer.invalidate()
            MiniMedKitCommandPackets.bolusTimer = nil
        }

        logger.info("MiniMedFlex simulator has been stopped!")
    }

    func notifyStateDidUpdate() {
        storageDelegate?.saveState(MiniMedKitPumpManager.self, self)
    }
}
