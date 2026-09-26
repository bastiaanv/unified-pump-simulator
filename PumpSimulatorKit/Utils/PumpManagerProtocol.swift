import Foundation
import SwiftUI

public typealias StateRawValue = [String: Any]

public protocol StorageDelegate {
    func saveState(_ pumpManager: PumpManagerProtocol.Type, _ state: PumpManagerProtocol)
}

public protocol PumpManagerProtocol {
    /// The identifier of pumpManager
    static var identifier: String { get }

    /// The title of the pumpManager
    var title: String { get }

    var rawState: StateRawValue { get }
    var storageDelegate: StorageDelegate? { get set }

    /// Lists all of the capabities this pumpManager has
    var capabilities: PumpManagerCapabitilties { get }

    var expiresAt: Date? { get }
    var activatedAt: Date? { get }
    var batteryLevel: String? { get }
    var basalState: BasalState { get }
    var basal: [BasalItem] { get set }
    var reservoirLevel: Double { get }

    var currentModel: PumpModel { get set }
    var pumpNotes: String { get }
    var pumpState: String { get }

    var bolusProgress: BolusState? { get }

    init(rawValue: StateRawValue, bluetoothManager: PumpBluetoothmanager)

    /// Start advertising bluetooth device
    func startAdvertising()

    /// Force the PumpManager to go back to its initial state
    func reset()

    /// Stops everything related to this pumpManager.
    /// The pumpManager is put on the background
    func stop()
}

public struct PumpManagerCapabitilties {
    /// A list of all supported pumps on this simulator
    public let supportedModels: [PumpModel]

    /// Pods/patches can expire, classic pumps do not
    public let canExpire: Bool

    public var actions: [PumpManagerActions]

    /// Continuous values a pump exposes for tinkering, rendered as sliders next to the actions
    public var sliders: [PumpManagerSlider] = []
}

public struct PumpManagerActions: Identifiable {
    public let id = UUID()
    public let label: String
    public let action: () -> Void
}

/// A value the simulator lets you drag through a range, for the parts of a pump that are not a
/// button press - filling a patch with insulin, say
public struct PumpManagerSlider: Identifiable {
    public let id = UUID()
    public let label: String
    public let range: ClosedRange<Double>
    public let step: Double
    public let unit: String

    /// The value to start the slider at
    public let get: () -> Double

    /// Called when the drag ends, not while it is in flight: a pump manager reacts to this by
    /// telling the connected app, and that should not run on every pixel of travel
    public let set: (Double) -> Void

    public init(
        label: String,
        range: ClosedRange<Double>,
        step: Double,
        unit: String,
        get: @escaping () -> Double,
        set: @escaping (Double) -> Void
    ) {
        self.label = label
        self.range = range
        self.step = step
        self.unit = unit
        self.get = get
        self.set = set
    }
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

public enum BasalState {
    case suspended(start: Date, duration: TimeInterval?)
    case active(rate: Double)
    case tempBasal(rate: Double, start: Date, end: Date)
}

public struct BolusState {
    public var total: Double
    public var progress: Double
}
