import Foundation

public protocol PumpManagerProtocol {
    /// The title of the pumpManager
    var title: String { get }
    
    /// Lists all of the capabities this pumpManager has
    var capabilities: PumpManagerCapabitilties { get }
    
    var expiresAt: Date? { get }
    var activatedAt: Date? { get }
    
    /// Start advertising bluetooth device
    func startAdvertising()
    
    /// Stops advertising bluetooth device
    func stopAdvertising()
    
    /// Stops everything related to this pumpManager.
    /// The pumpManager is put on the background
    func stop()
}

public struct PumpManagerCapabitilties {
    /// Pods/patches can expire, classic pumps do not
    let canExpire: Bool
}
