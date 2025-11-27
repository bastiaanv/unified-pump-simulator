import Foundation

public class DanaKitPumpManager : PumpManagerProtocol {
    public static let identifier: String = "danakit"
    public let title: String = "DanaKit"
    
    public let capabilities: PumpManagerCapabitilties = PumpManagerCapabitilties(
        supportedModels: [
            DanaPump.DanaRSv3.getPumpModel(),
            DanaPump.DanaI.getPumpModel()
        ],
        canExpire: false
    )
    
    public var expiresAt: Date? = nil
    public var activatedAt: Date? = nil
    
    public var currentModel: PumpModel {
        state.pumpModel.getPumpModel()
    }
    
    public var basal: [BasalItem] {
        get { state.basal }
        set {
            state.basal = newValue
            storageDelegate?.saveState(DanaKitPumpManager.self, state.getRaw())
        }
    }
    
    public var rawState: StateRawValue {
        state.getRaw()
    }
    
    public var storageDelegate: (any StorageDelegate)?
    
    let state: DanaKitState
    private let logger = PumpManagerLogger(subsystem: "com.bastiaanv.danaKit", category: "DanaKitBluetoothManager")
    private let bluetooth = DanaKitBluetoothManager()
    public required init(rawValue: StateRawValue) {
        state = DanaKitState(rawValue: rawValue)
        bluetooth.pumpManagerDelegate = self
    }
    
    public func startAdvertising() {
        bluetooth.startAdvertising()
    }
    
    public func stop() {
        bluetooth.stopAdvertising()
        
        logger.info("DanaKit simulator has been stopped!")
    }
}
