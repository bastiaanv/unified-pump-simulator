import Foundation

/// Device-Time control point (`packets/06 §2`).
///
/// Request (13 B): `[op:1][flags:2][baseTime:4][offset:1][tz:5]` where `op` is
/// `2` (propose) or `3` (force) time update.
/// Read response (17 B): `[baseTime:4][offset:1][t:4][tz:1][flags:2][tzAbbr:5]`.
/// Control-point ack: `[resOp 0x09][requestOp 2/3][responseValue u8][rejectionFlags i16]`.
enum MiniMedKitTimePackets {
    static let logger = PumpManagerLogger(subsystem: "com.bastiaanv.minimedkit", category: "MiniMedKitTimePackets")

    /// Date used for Medtronic `baseTime` (seconds since 2000-01-01).
    private static let epoch2000 = Date(timeIntervalSince1970: 946_684_800)

    static func process(_ payload: Data, _ params: MiniMedKitBluetoothManager.PacketParams) -> Bool {
        let op = payload.first
        // Time-update proposal (`2`) / force (`3`).
        if op == 2 || op == 3 {
            applyTimeUpdate(payload, params)
            return true
        }

        // Otherwise treat as a device-time read and return the 17-byte response.
        if op == nil || op == 1 {
            sendReadResponse(params)
            return true
        }

        return false
    }

    private static func applyTimeUpdate(_ payload: Data, _ params: MiniMedKitBluetoothManager.PacketParams) {
        let op = payload.count >= 1 ? payload[0] : 0
        // baseTimeUpdateInSeconds / therapy offset are echoed back to the phone.
        let ack = Data([0x09, op, 0x01, 0x00, 0x00])
        params.manager.sendCCMP(
            messageID: CcmpMsgID.deviceTime.rawValue,
            payload: ack,
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )
        logger.info("Applied device-time update (op \(op))")
    }

    private static func sendReadResponse(_ params: MiniMedKitBluetoothManager.PacketParams) {
        var response = Data()
        let baseTime = UInt32(Date().timeIntervalSince(epoch2000))
        response.append(baseTime.miniMedData()) // baseTime u32
        response.append(0x00) // offset i8
        response.append(Int32(0).miniMedData()) // time value i32
        response.append(0x00) // timezone u8
        response.append(UInt16(0x0002).miniMedData()) // flags: utcAligned
        response.append("CET  ".data(using: .ascii) ?? Data(repeating: 0x20, count: 5))

        params.manager.sendCCMP(
            messageID: CcmpMsgID.deviceTime.rawValue,
            payload: response,
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )
        logger.info("Sent device-time read response (17 B)")
    }
}
