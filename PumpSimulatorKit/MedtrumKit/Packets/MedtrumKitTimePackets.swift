import Foundation

extension MedtrumKitPackets {
    static func parseGetTime(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        bluetoothManager.writeResponse(
            data: Date.now.toMedtrumSeconds(),
            status: .ok,
            params.responseParam
        )
        logger.info("Processed GetTime message!")
    }

    static func parseSetTime(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        bluetoothManager.writeResponse(
            data: Data(),
            status: .ok,
            params.responseParam
        )
        logger.info("Processed SetTime message!")
    }

    static func parseSetTimeZone(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        bluetoothManager.writeResponse(
            data: Data(),
            status: .ok,
            params.responseParam
        )
        logger.info("Processed SetTimeZone message!")
    }
}
