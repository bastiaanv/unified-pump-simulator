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
        managers = [
            Managers(icon: "1.circle", manager: DanaKitPumpManager(rawValue: storage.getState(DanaKitPumpManager.self) ?? [:])),
            Managers(
                icon: "2.circle",
                manager: MedtrumKitPumpManager(rawValue: storage.getState(MedtrumKitPumpManager.self) ?? [:])
            ),
        ]
    }

    var body: some Scene {
        WindowGroup {
            MainView(pumpManagers: managers)
        }
    }
}
