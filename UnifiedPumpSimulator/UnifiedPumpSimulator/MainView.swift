import PumpSimulatorKit
import SwiftUI

struct MainView: View {
    @State var pumpManagers: [Managers]

    var body: some View {
        TabView {
            ForEach($pumpManagers) { $item in
                SimulatorView(viewModel: SimulatorViewModel(pumpManager: $item.manager.wrappedValue))
                    .tabItem {
                        Label($item.manager.wrappedValue.title, systemImage: $item.icon.wrappedValue)
                    }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
