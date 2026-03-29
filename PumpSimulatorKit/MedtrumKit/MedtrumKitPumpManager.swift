import Foundation
import SwiftUI

public class MedtrumKitPumpManager: PumpManagerProtocol {
    public static let identifier: String = "medtrumkit"
    public var title: String = "MedtrumKit"

    public let capabilities = PumpManagerCapabitilties(
        supportedModels: [
            PumpModel(name: "200U", image: Image(imageName: "nano200"), index: 0),
            PumpModel(name: "300U", image: Image(imageName: "nano300"), index: 1),
        ],
        canExpire: true
    )

    public var currentModel: PumpModel {
        get {
            capabilities.supportedModels.first(where: { $0.index == state.currentModelIndex }) ?? PumpModel(
                name: "200U",
                image: Image(imageName: "nano200"),
                index: 0
            )
        }
        set {
            state.currentModelIndex = newValue.index
        }
    }

    public var pumpState: String {
        state.patchState.title
    }

    public var pumpNotes: String {
        "Pump base serial number: 4A12D828"
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
        if state.patchState == .suspended, let suspendedSince = state.suspendedSince {
            return .suspended(start: suspendedSince)

        } else if let percentage = state.tempBasalPercentage,
                  let start = state.tempBasalStart,
                  let duration = state.tempBasalDuration
        {
            return .tempBasal(
                rate: state.currentBaseBasalRate * (Double(percentage) / 100),
                start: start,
                end: start + duration
            )

        } else {
            return .active(rate: state.currentBaseBasalRate)
        }
    }

    public var storageDelegate: (any StorageDelegate)?
    public var rawState: StateRawValue {
        state.getRaw()
    }

    private let logger = PumpManagerLogger(subsystem: "com.bastiaanv.medtrumkit", category: "MedtrumKitPumpManager")
    private let bluetooth: MedtrumKitBluetoothManager
    let state: MedtrumKitState
    var isRunning: Bool = false

    public required init(rawValue: StateRawValue, bluetoothManager: PumpBluetoothmanager) {
        state = MedtrumKitState(rawValue: rawValue)
        bluetooth = MedtrumKitBluetoothManager(pumpBluetoothManager: bluetoothManager)

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

    public func stop() {
        bluetooth.stopAdvertising()
        isRunning = false

        logger.info("MedtrumKit simulator has been stopped!")
    }

    func notifyStateDidUpdate() {
        storageDelegate?.saveState(MedtrumKitPumpManager.self, self)
    }
}
