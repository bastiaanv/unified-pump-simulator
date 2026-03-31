import Foundation

extension MedtrumKitPackets {
    static func parseAuthorizePacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        // Return hardcoded response
        // No need to check session token nor SN
        let response = Data(hex: "025801505300003a00")

        bluetoothManager.writeResponse(data: response, status: .ok, params.responseParam)
        logger.info("Processed Auth message!")
    }

    static func parseSubscribePacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        // 0704020000007900 <-- Expected response
        let response = Data([])

        bluetoothManager.writeResponse(data: response, status: .ok, params.responseParam)
        logger.info("Processed Subscribe message!")
    }
}
