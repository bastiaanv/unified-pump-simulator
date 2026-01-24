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
                currentPump = selectedPump
            }
        }
    }

    let pumpManager: PumpManagerProtocol

    init(pumpManager: PumpManagerProtocol) {
        self.pumpManager = pumpManager

        supportedPumpModels = pumpManager.capabilities.supportedModels
        currentPump = pumpManager.currentModel
        currentPumpIndex = currentPump.index

        PumpManagerLogger.addObserver(self)
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

extension SimulatorViewModel: LoggerObserver {
    func logsUpdated(_ lines: [PumpSimulatorKit.LogLine]) {
        DispatchQueue.main.async {
            self.logLines = lines.reversed()
        }
    }
}
