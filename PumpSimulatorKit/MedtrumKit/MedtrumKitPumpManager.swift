import Foundation

public class MedtrumKitPumpManager : PumpManagerProtocol {
    public var title: String = "MedtrumKit"
    
    public let capabilities = PumpManagerCapabitilties(
        canExpire: true
    )
    
    public var expiresAt: Date? {
        state.expiresAt
    }
    
    public var activatedAt: Date? {
        state.activatedAt
    }
    
    private let state: MedtrumKitState
    public init() {
        state = MedtrumKitState()
    }
    
    public func startAdvertising() {
        // TODO:
    }
    
    public func stopAdvertising() {
        // TODO:
    }
    
    public func stop() {
        // TODO: Stop adverting & kill bluetooth manager
    }
}
