import PumpSimulatorKit
import SwiftUI

struct SimulatorView: View {
    @ObservedObject var viewModel: SimulatorViewModel

    var body: some View {
        VStack {
            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    PumpSelector
                    Divider()
                    PumpState
                    Divider()
                    PumpActions
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            LoggerView
        }
        .onDisappear {
            viewModel.pumpManager.stop()
            viewModel.simulatorRunning = false
        }
        .navigationTitle("Unified pump simulator - " + viewModel.pumpManager.title)
    }

    var PumpSelector: some View {
        VStack {
            viewModel.currentPump.image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: 100, maxHeight: 200)

            if viewModel.supportedPumpModels.count > 1 {
                Text("Select your pump model")
                    .bold()

                Picker("", selection: $viewModel.currentPumpIndex) {
                    ForEach($viewModel.supportedPumpModels) { $item in
                        Text($item.wrappedValue.name).tag($item.wrappedValue.index)
                    }
                }
                .disabled(viewModel.simulatorRunning)
                .pickerStyle(.segmented)
                .padding(.bottom, 10)
            }

            if !viewModel.simulatorRunning {
                Button(action: { viewModel.startSimulator() }) {
                    Text("Start simulator")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(BlueButtonStyle(primaryColor: Color.blue))
            } else {
                Button(action: { viewModel.stopSimulator() }) {
                    Text("Stop simulator")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(BlueButtonStyle(primaryColor: Color.red))
            }

            Button(action: { viewModel.resetSimulator() }) {
                Text("Reset Pump")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .disabled(viewModel.simulatorRunning)
            .buttonStyle(BlueButtonStyle(primaryColor: Color.red))
        }
        .frame(maxWidth: 200)
    }

    var PumpState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pump Status")
                .font(.title3)
                .bold()

            if !viewModel.pumpState.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.blue)

                    Text("Pump state:")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(viewModel.pumpState)
                        .foregroundStyle(.primary)
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "cross.vial.fill")
                    .font(.callout)
                    .foregroundStyle(.blue)

                Text("Reservoir level:")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("\(viewModel.reservoirLevel)U")
                    .foregroundStyle(.primary)
            }

            HStack(spacing: 5) {
                Image(systemName: viewModel.basalIcon)
                    .font(.callout)
                    .foregroundStyle(.blue)

                Text("Basal state:")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(viewModel.basalState)
                    .foregroundStyle(.primary)
            }

            if !viewModel.batteryLevel.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "battery.100percent")
                        .font(.callout)
                        .foregroundStyle(.blue)

                    Text("Battery level:")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(viewModel.batteryLevel)
                        .foregroundStyle(.primary)
                }
            }

            if let activatedAt = viewModel.activatedAt {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        .font(.callout)
                        .foregroundStyle(.blue)

                    Text("Activated at:")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(activatedAt)
                        .foregroundStyle(.primary)
                }
            }

            if let bolusProgress = viewModel.bolusProgress {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Bolus progress")
                        .font(.title3)
                        .bold()
                        .padding(.top, 10)

                    ProgressView(value: min(bolusProgress.progress, bolusProgress.total), total: bolusProgress.total)
                        .frame(width: 200)
                    Text(
                        "\(viewModel.basalFormatter.string(from: bolusProgress.progress as NSNumber) ?? "") U of \(viewModel.basalFormatter.string(from: bolusProgress.total as NSNumber) ?? "") U"
                    )
                }
            }

            Spacer()
            Text("Pump Notes")
                .font(.title3)
                .bold()

            Text(viewModel.pumpNotes)
                .foregroundStyle(.primary)
        }
        .padding(.all, 10)
    }

    var PumpActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !viewModel.pumpManagerAction.isEmpty {
                Text("Actions")
                    .font(.title3)
                    .bold()
            }

            ForEach(viewModel.pumpManagerAction) { action in
                Button(action: action.action) {
                    Text(action.label)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(BlueButtonStyle(primaryColor: Color.blue))
                .disabled(!viewModel.simulatorRunning)
            }
        }
        .padding(.all, 10)
    }

    var LoggerView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach($viewModel.logLines) { line in
                    Text(line.wrappedValue.message)
                        .textSelection(.enabled)
                        .padding(.horizontal)
                        .foregroundStyle(getColor(line.wrappedValue.level))

                    Text(line.wrappedValue.submessage + " - " + line.wrappedValue.functionInfo)
                        .textSelection(.enabled)
                        .padding(.horizontal)
                        .foregroundStyle(Color.gray)
                        .font(.footnote)

                    Divider()
                }
            }
            .padding(.top, 5)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    func getColor(_ value: String) -> Color {
        switch value {
        case "ERROR":
            return Color.red
        case "WARNING":
            return Color.yellow
        case "DEBUG":
            // 46, 77, 128
            return Color(red: 0.180, green: 0.302, blue: 0.502)
        default:
            return Color.primary
        }
    }
}

struct BlueButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled
    let primaryColor: Color
    var textColor: Color = .white

    func makeBody(configuration: Self.Configuration) -> some View {
        configuration.label
            .foregroundColor(textColor.opacity(!configuration.isPressed && isEnabled ? 1 : 0.3))
            .background(primaryColor.opacity(!configuration.isPressed && isEnabled ? 1 : 0.3))
            .cornerRadius(6.0)
    }
}
