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

    /// SetTimeZone: the offset from UTC in minutes (2 bytes, two's complement) and the phone's time (4)
    static func parseSetTimeZone(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        if params.data.count >= 6 {
            let offset = Int(Int16(bitPattern: params.data.toUInt16(offset: 4)))
            params.pumpManager.state.setTimeZone(offset: offset, at: .now)
            params.pumpManager.notifyStateDidUpdate()
            let sign = offset < 0 ? "-" : "+"
            logger.info("Time zone set: UTC\(sign)\(abs(offset) / 60):\(String(format: "%02d", abs(offset) % 60))")
        } else {
            logger.warning("SetTimeZone message too short: \(params.data.hexString())")
        }

        bluetoothManager.writeResponse(
            data: Data(),
            status: .ok,
            params.responseParam
        )
        logger.info("Processed SetTimeZone message!")
    }
}
