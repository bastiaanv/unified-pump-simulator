import Combine
import PumpSimulatorKit
import SwiftUI

class SimulatorViewModel: ObservableObject {
    @Published var logLines: [LogLine] = []
    @Published var simulatorRunning = false
    @Published var supportedPumpModels: [PumpModel] = []
    @Published var currentPump: PumpModel
    @Published var currentPumpIndex: Int = 0 {
        didSet {
            if let selectedPump = supportedPumpModels.first(where: { $0.index == currentPumpIndex }) {
                DispatchQueue.main.async {
                    self.currentPump = selectedPump
                    self.pumpManager.currentModel = selectedPump
                    self.pumpNotes = self.pumpManager.pumpNotes
                }
            }
        }
    }

    @Published var reservoirLevel: String = "0"
    @Published var basalState: String = ""
    @Published var basalIcon: String = "play.fill"
    @Published var batteryLevel: String = ""
    @Published var pumpNotes: String = ""
    @Published var pumpState: String = ""

    let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    let basalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()

    let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()

    let storage = Storage()
    var pumpManager: PumpManagerProtocol

    init(pumpManager: PumpManagerProtocol) {
        self.pumpManager = pumpManager

        supportedPumpModels = pumpManager.capabilities.supportedModels
        currentPump = pumpManager.currentModel
        currentPumpIndex = currentPump.index

        self.pumpManager.storageDelegate = self
        PumpManagerLogger.addObserver(self)

        updateState(pumpManager: pumpManager)
    }

    func startSimulator() {
        pumpManager.startAdvertising()
        simulatorRunning = true
    }

    func stopSimulator() {
        pumpManager.stop()
        simulatorRunning = false
    }
}

extension SimulatorViewModel: StorageDelegate {
    func saveState(
        _ pumpManagerType: any PumpSimulatorKit.PumpManagerProtocol.Type,
        _ pumpManager: any PumpSimulatorKit.PumpManagerProtocol
    ) {
        storage.saveState(pumpManagerType, pumpManager)
        updateState(pumpManager: pumpManager)
    }

    func updateState(pumpManager: any PumpManagerProtocol) {
        DispatchQueue.main.async {
            self.pumpNotes = self.pumpManager.pumpNotes
            self.pumpState = self.pumpManager.pumpState
            self.reservoirLevel = self.integerFormatter.string(from: pumpManager.reservoirLevel as NSNumber) ?? "0"

            if let battery = pumpManager.batteryLevel {
                self.batteryLevel = battery
            } else {
                self.batteryLevel = ""
            }

            switch pumpManager.basalState {
            case let .suspended(start):
                self.basalIcon = "pause.fill"
                self.basalState = "Suspended - since: \(self.timeFormatter.string(from: start))"
            case let .tempBasal(rate, _, _):
                self.basalIcon = "bolt.fill"
                self.basalState = "Temp basal - rate: \(self.basalFormatter.string(from: rate as NSNumber) ?? "0") U/hr"
            case let .active(rate):
                self.basalIcon = "play.fill"
                self.basalState = "Active - rate: \(self.basalFormatter.string(from: rate as NSNumber) ?? "0") U/hr"
            @unknown default:
                break
            }
        }
    }
}

extension SimulatorViewModel: LoggerObserver {
    func logsUpdated(_ lines: [PumpSimulatorKit.LogLine]) {
        DispatchQueue.main.async {
            self.logLines = lines.reversed()
        }
    }
}
