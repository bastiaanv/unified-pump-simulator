import SwiftUI
import PumpSimulatorKit

struct SimualtorView: View {
    var pumpManager: PumpManagerProtocol
    
    var body: some View {
        VStack {
            Button(action: { pumpManager.startAdvertising() }) {
                Text("Start advertising")
            }
        }
        .onDisappear {
            pumpManager.stop()
        }
        .navigationTitle("Unified pump simulator - " + pumpManager.title)
    }
}

#Preview {
    MainView()
}
