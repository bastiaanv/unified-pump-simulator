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

    /// Settings a pump exposes for tinkering beyond a button or a slider - a fault to inject into the next command,
    /// say - grouped and laid out in rows
    public var controlGroups: [PumpManagerControlGroup] = []

    /// Read-only tables a pump keeps up to date - its event log, the faults it has armed
    public var lists: [PumpManagerList] = []
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

    /// Whether the value can be changed now - read on every state update, like `get`. A disabled slider still shows
    /// the value, so it reads as a gauge.
    public let isEnabled: () -> Bool

    /// Shown under the slider: when it can be used, say
    public let note: String?

    public init(
        label: String,
        range: ClosedRange<Double>,
        step: Double,
        unit: String,
        note: String? = nil,
        isEnabled: @escaping () -> Bool = { true },
        get: @escaping () -> Double,
        set: @escaping (Double) -> Void
    ) {
        self.label = label
        self.range = range
        self.step = step
        self.unit = unit
        self.note = note
        self.isEnabled = isEnabled
        self.get = get
        self.set = set
    }
}

/// A titled block of rows of controls, with an optional note under them on what they do
public struct PumpManagerControlGroup: Identifiable {
    public let id = UUID()
    public let title: String
    public let rows: [PumpManagerControlRow]
    public let footnote: String?

    public init(title: String, rows: [PumpManagerControlRow], footnote: String? = nil) {
        self.title = title
        self.rows = rows
        self.footnote = footnote
    }
}

/// One line of a control group: a label and the controls next to it, and an optional line of text under the label -
/// what the row does
public struct PumpManagerControlRow: Identifiable {
    public let id = UUID()
    public let label: String
    public let detail: String?
    public let controls: [PumpManagerControl]

    public init(label: String, detail: String? = nil, controls: [PumpManagerControl]) {
        self.label = label
        self.detail = detail
        self.controls = controls
    }
}

/// A setting the simulator renders as a picker, a toggle or a number field, or a button. It reads its value through
/// `get` every time it is drawn, so a pump manager can change it behind the UI's back (a fault armed for one command,
/// say, that went back to normal once used) and the UI follows on its next refresh.
public struct PumpManagerControl: Identifiable {
    public enum Kind {
        case picker(options: [String], get: () -> Int, set: (Int) -> Void)
        case toggle(get: () -> Bool, set: (Bool) -> Void)
        case number(range: ClosedRange<Double>, step: Double, unit: String, get: () -> Double, set: (Double) -> Void)
        /// A one-off action - arming a set of faults at once, say
        case button(action: () -> Void)
    }

    public let id = UUID()
    public let label: String
    public let kind: Kind

    public init(label: String, kind: Kind) {
        self.label = label
        self.kind = kind
    }

    public static func picker(
        _ label: String,
        options: [String],
        get: @escaping () -> Int,
        set: @escaping (Int) -> Void
    ) -> Self {
        PumpManagerControl(label: label, kind: .picker(options: options, get: get, set: set))
    }

    public static func toggle(_ label: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> Self {
        PumpManagerControl(label: label, kind: .toggle(get: get, set: set))
    }

    public static func number(
        _ label: String,
        range: ClosedRange<Double>,
        step: Double = 1,
        unit: String = "",
        get: @escaping () -> Double,
        set: @escaping (Double) -> Void
    ) -> Self {
        PumpManagerControl(label: label, kind: .number(range: range, step: step, unit: unit, get: get, set: set))
    }

    public static func button(_ label: String, action: @escaping () -> Void) -> Self {
        PumpManagerControl(label: label, kind: .button(action: action))
    }
}

/// A table the simulator shows and refreshes whenever the pump's state changes
public struct PumpManagerList: Identifiable {
    public let id = UUID()
    public let title: String
    public let columns: [String]
    /// Shown instead of the table when there are no rows
    public let emptyText: String
    /// Each row holds one value per column
    public let rows: () -> [[String]]

    public init(title: String, columns: [String], emptyText: String = "Nothing yet", rows: @escaping () -> [[String]]) {
        self.title = title
        self.columns = columns
        self.emptyText = emptyText
        self.rows = rows
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
