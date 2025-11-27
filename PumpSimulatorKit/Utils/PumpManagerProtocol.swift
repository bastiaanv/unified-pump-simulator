import Foundation
import SwiftUI

public typealias StateRawValue = [String: Any]

public protocol StorageDelegate {
    func saveState(_ pumpManager: PumpManagerProtocol.Type, _ state: StateRawValue)
}

public protocol PumpManagerProtocol {
    /// The identifier of pumpManager
    static var identifier: String { get }
    
    /// The title of the pumpManager
    var title: String { get }
    
    var storageDelegate: StorageDelegate? { get set }
    
    /// Lists all of the capabities this pumpManager has
    var capabilities: PumpManagerCapabitilties { get }
    
    var expiresAt: Date? { get }
    var activatedAt: Date? { get }
    var basal: [BasalItem] { get set }
    
    var currentModel: PumpModel { get }
    
    init(rawValue: StateRawValue)
    
    /// Start advertising bluetooth device
    func startAdvertising()
    
    /// Stops everything related to this pumpManager.
    /// The pumpManager is put on the background
    func stop()
}

public struct PumpManagerCapabitilties {
    /// A list of all supported pumps on this simulator
    public let supportedModels: [PumpModel]
    
    /// Pods/patches can expire, classic pumps do not
    public let canExpire: Bool
}

public struct PumpModel: Identifiable {
    public let id = UUID()
    public let name: String
    public let image: Image
    public let index: Int
}

public struct BasalItem: Identifiable, Codable {
    public var id = UUID()
    public let start: TimeInterval
    public let rate: Double
}
