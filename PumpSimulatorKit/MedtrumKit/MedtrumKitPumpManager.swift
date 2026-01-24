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

    public var batteryLevel: Double? {
        nil
    }

    public var reservoirLevel: Double {
        state.reservoirLevel
    }

    public var basalState: BasalState {
        // TODO:
        .suspended(start: Date.now)
    }

    public var storageDelegate: (any StorageDelegate)?
    public var rawState: StateRawValue {
        state.getRaw()
    }

    private let state: MedtrumKitState
    public required init(rawValue: StateRawValue) {
        state = MedtrumKitState(rawValue: rawValue)
    }

    public func startAdvertising() {
        // TODO:
    }

    public func stop() {
        // TODO: Stop adverting & kill bluetooth manager
    }

    func notifyStateDidUpdate() {
        storageDelegate?.saveState(MedtrumKitPumpManager.self, self)
    }
}
