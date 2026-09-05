import Foundation

/// Status & history handlers — RACP (record access) and SRCP (status control).
/// `packets/06 §3/§4`. These ride as CCMP payloads.
enum FlexKitStatusPackets {
    static let logger = PumpManagerLogger(subsystem: "com.bastiaanv.flexkit", category: "FlexKitStatusPackets")

    static func process(_ payload: Data, _ params: FlexKitBluetoothManager.PacketParams) -> Bool {
        // RACP history request `[0x66][operator][0x1E][start:4][end:4]`.
        if payload.count >= 3, payload[0] == 0x66 {
            processRacp(payload, params)
            return true
        }

        // SRCP status getter `[opcode u16 LE]`.
        if payload.count >= 2 {
            processSrcp(payload, params)
            return true
        }

        return false
    }

    // MARK: - RACP history

    private static func processRacp(_ payload: Data, _ params: FlexKitBluetoothManager.PacketParams) {
        let operatorValue = payload.miniMedUInt8(1)
        let records = params.pumpManager.state.historyRecords

        // Report each stored record as its own CCMP frame (11-byte header + data,
        // per `IddHistoryRecordDecoder`).
        for record in records {
            var body = Data()
            body.append(record.type.miniMedData())
            body.append(record.seqNumber.miniMedData())
            body.append(record.baseTime.miniMedData())
            body.append(record.sessionId)
            body.append(record.data)

            params.manager.sendCCMP(
                messageID: CcmpMsgID.racp.rawValue,
                payload: body,
                to: params.manager.data7102,
                peripheralManager: params.peripheralManager
            )
        }

        // Final response code: `[op][operator echo][code]` (success).
        let done = Data([0x06, operatorValue, 0x01])
        params.manager.sendCCMP(
            messageID: CcmpMsgID.racp.rawValue,
            payload: done,
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )
        logger.info("Sent \(records.count) history record(s)")
    }

    // MARK: - SRCP status

    private static func processSrcp(_ payload: Data, _ params: FlexKitBluetoothManager.PacketParams) {
        let opcode = payload.miniMedUInt16(0)
        let state = params.pumpManager.state

        // Generic SRCP response: `[opcode u16][opcodeEcho u16][responseCode u8][payload…]`.
        var body = Data()
        body.append(opcode.miniMedData())
        body.append(opcode.miniMedData()) // echo
        body.append(0x0F) // response code (=15)

        // Append a small status payload so the phone can read values.
        var status = Data()
        let reservoirMU = UInt32(state.reservoirLevel * 1000)
        status.append(reservoirMU.miniMedData()) // reservoir mU
        let batteryPct = UInt8(max(0, min(100, state.batteryLevel)))
        status.append(batteryPct) // battery %
        let basalMU = UInt32(state.currentBaseBasalRate * 1000)
        status.append(basalMU.miniMedData()) // basal mU
        body.append(status)

        params.manager.sendCCMP(
            messageID: CcmpMsgID.srcp.rawValue,
            payload: body,
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )
        logger.info("Sent SRCP status (opcode \(opcode))")
    }
}
