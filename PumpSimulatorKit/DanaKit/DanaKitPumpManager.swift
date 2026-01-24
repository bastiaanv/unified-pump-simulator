import Foundation

public class DanaKitPumpManager: PumpManagerProtocol {
    public static let identifier: String = "danakit"
    public let title: String = "DanaKit"

    public let capabilities: PumpManagerCapabitilties = .init(
        supportedModels: [
            DanaPump.DanaRSv3.getPumpModel(),
            DanaPump.DanaI.getPumpModel(),
        ],
        canExpire: false
    )

    public var expiresAt: Date?
    public var activatedAt: Date?

    public var currentModel: PumpModel {
        get { state.pumpModel.getPumpModel() }
        set { state.pumpModel = DanaPump(rawValue: UInt8(newValue.index)) ?? .DanaI }
    }

    public var pumpNotes: String {
        switch state.pumpModel {
        case .DanaI:
            return "Bluetooth name: \(bluetooth.LOCAL_DEVICE_NAME)"
        case .DanaRSv3:
            return "Bluetooth name: \(bluetooth.LOCAL_DEVICE_NAME)\nPin 1: \(DanaKitEncryption.pairingKeys.hexString())\nPin 2: \(DanaKitEncryption.randomPairingKeys.hexString())"
        case .DanaRSv1:
            return "Not implemented..."
        }
    }

    public var basalState: BasalState {
        if let suspendedSince = state.suspendedSince {
            return .suspended(start: suspendedSince)
        } else if let percentage = state.tempBasalPercentage, let duration = state.tempBasalDuration,
                  let start = state.tempBasalStart
        {
            let rate = Double(percentage) * currentBaseBasalRate
            return .tempBasal(rate: rate, start: start, end: start + duration)
        } else {
            return .active(rate: currentBaseBasalRate)
        }
    }

    public var basal: [BasalItem] {
        get { state.basal }
        set {
            state.basal = newValue
            notifyStateUpdate()
        }
    }

    public var batteryLevel: Double? {
        Double(state.batteryPercentage)
    }

    public var reservoirLevel: Double {
        state.reservoirLevel
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

    func notifyStateUpdate() {
        storageDelegate?.saveState(DanaKitPumpManager.self, self)
    }

    private var currentBaseBasalRate: Double {
        guard !state.basal.isEmpty else {
            // Prevent crash if basalSchedule isnt set
            return 0
        }

        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let nowTimeInterval = now.timeIntervalSince(startOfDay)

        let index = (state.basal.firstIndex(where: { $0.start > nowTimeInterval }) ?? 24) - 1
        return state.basal.indices.contains(index) ? state.basal[index].rate : 0
    }
}
