import SwiftUI
import PumpSimulatorKit

struct Managers: Identifiable {
    let id = UUID()
    var icon: String
    var manager: PumpManagerProtocol
}

struct MainView: View {
    @State var pumpManagers: [Managers] = [
        Managers(icon: "1.circle", manager: DanaKitPumpManager()),
        Managers(icon: "2.circle", manager: MedtrumKitPumpManager())
    ]
    
    var body: some View {
        TabView {
            ForEach($pumpManagers) { $item in
                SimualtorView(pumpManager: $item.manager.wrappedValue)
                .tabItem {
                    Label($item.manager.wrappedValue.title, systemImage: $item.icon.wrappedValue)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .navigationTitle("Unified pump simulator")
    }
}

#Preview {
    MainView()
}
