import Foundation
import SwiftUI

public class MedtrumKitPumpManager : PumpManagerProtocol {
    public static let identifier: String = "medtrumkit"
    public var title: String = "MedtrumKit"
    
    public let capabilities = PumpManagerCapabitilties(
        supportedModels: [
            PumpModel(name: "200U", image: Image(imageName: "nano200"), index: 0),
            PumpModel(name: "300U", image: Image(imageName: "nano300"), index: 1)
        ],
        canExpire: true
    )
    
    public var currentModel: PumpModel {
        capabilities.supportedModels.first(where: { $0.index == state.currentModelIndex }) ??
        PumpModel(name: "200U", image: Image(imageName: "nano200"), index: 0)
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
            storageDelegate?.saveState(MedtrumKitPumpManager.self, state.getRaw())
        }
    }
    
    public var storageDelegate: (any StorageDelegate)?
    
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
}
