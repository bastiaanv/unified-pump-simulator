import PumpSimulatorKit
import SwiftData
import SwiftUI

struct Managers: Identifiable {
    let id = UUID()
    var icon: String
    var manager: PumpManagerProtocol
}

@main struct UnifiedPumpSimulatorApp: App {
    private let managers: [Managers]
    init() {
        let storage = Storage()
        let bluetooth = PumpBluetoothmanager()

        managers = [
            Managers(
                icon: "1.circle",
                manager: DanaKitPumpManager(
                    rawValue: storage.getState(DanaKitPumpManager.self) ?? [:],
                    bluetoothManager: bluetooth
                )
            ),
            Managers(
                icon: "2.circle",
                manager: MedtrumKitPumpManager(
                    rawValue: storage.getState(MedtrumKitPumpManager.self) ?? [:],
                    bluetoothManager: bluetooth
                )
            ),
        ]
    }

    var body: some Scene {
        WindowGroup {
            MainView(pumpManagers: managers)
        }
    }
}
