import Foundation

public class DanaKitPumpManager : PumpManagerProtocol {
    public let title: String = "DanaKit"
    
    public let capabilities: PumpManagerCapabitilties = PumpManagerCapabitilties(
        canExpire: false
    )
    
    public var expiresAt: Date? = nil
    public var activatedAt: Date? = nil
    
    private let state = DanaKitState()
    private let bluetooth = DanaKitBluetoothManager()
    public init() { }
    
    public func startAdvertising() {
        bluetooth.startAdvertising()
    }
    
    public func stopAdvertising() {
        bluetooth.stopAdvertising()
    }
    
    public func stop() {
        // TODO: Stop adverting & kill bluetooth manager
    }
}
