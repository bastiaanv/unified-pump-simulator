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

        // Single RACP response frame. FlexKit delivers only the first CCMP
        // payload per request and parses one buffer (`IddRacp.decodeResponse`),
        // so everything must ride in ONE frame: response header first, then the
        // records. Layout: `[op=response(1)][operator echo][code=success(0)]`
        // then per record `[type u16][seq u32][baseTime u32][sessionId u8][data]`.
        var body = Data()
        body.append(0x01) // IdsRacpOpCode.response
        body.append(operatorValue) // operator echo
        body.append(0x00) // IdsRacpResponseCode.success

        for record in records {
            body.append(record.type.miniMedData())
            body.append(record.seqNumber.miniMedData())
            body.append(record.baseTime.miniMedData())
            body.append(record.sessionId)
            body.append(record.data)
        }

        params.manager.sendCCMP(
            messageID: CcmpMsgID.racp.rawValue,
            payload: body,
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )
        logger.info("Sent \(records.count) history record(s)")
    }

    // MARK: - SRCP status

    private static func processSrcp(_ payload: Data, _ params: FlexKitBluetoothManager.PacketParams) {
        let opcode = payload.miniMedUInt16(0)
        let state = params.pumpManager.state

        // Generic SRCP response header: `[opcode u16][opcodeEcho u16][responseCode u8]`.
        var body = Data()
        body.append(opcode.miniMedData())
        body.append(opcode.miniMedData()) // echo
        body.append(0x0F) // response code (=15, success)

        // Status-specific payload, matched to the FlexKit decoder layouts
        // (`IddSrcpStatus.swift`). Opcodes mirror FlexKit `IddSrcpOpCode`.
        var status = Data()
        switch opcode {
        case 2: // basalRateDelivery → `[flag u8][tempType u8][rate u32 mU/hr]`
            let flag: UInt8 = state.suspendedSince != nil ? 0 : 1 // ActiveBasalRateFlag
            let tempType: UInt8 = state.tempBasalRate != nil ? 2 : 0 // TempBasalRateType (0 none, 2 absolute)
            status.append(flag)
            status.append(tempType)
            status.append(UInt32((state.tempBasalRate ?? state.currentBaseBasalRate) * 1000).miniMedData())

        case 3: // getAlertStack → `[count u8][{id u16}{stateFlags u8} ×count]`
            status.append(UInt8(state.alertStack.count))
            for alert in state.alertStack {
                status.append(alert.id.miniMedData())
                status.append(alert.stateFlags)
            }

        case 7: // getInfusionSetupStatus → `[flags u8]` (0 = setup/fill complete)
            status.append(0x00)

        case 8: // insulinOnBoard → `[iob u32 mU][status u8]` (status 0 = valid)
            status.append(UInt32(state.insulinOnBoardUnits * 1000).miniMedData())
            status.append(0x00)

        case 15: // getBatteryStatus → `[remainingPercent u8][statusFlags u8]`
            status.append(UInt8(max(0, min(100, state.batteryLevel))))
            status.append(0x00)

        case 18: // getReservoirStatus → `[volumeStatus u8][amount u32 mU]` (0 ok, 2 empty)
            status.append(state.reservoirLevel <= 0 ? 2 : 0)
            status.append(UInt32(state.reservoirLevel * 1000).miniMedData())

        default:
            // Fallback generic status payload for unhandled opcodes.
            status.append(UInt32(state.reservoirLevel * 1000).miniMedData())
            status.append(UInt8(max(0, min(100, state.batteryLevel))))
            status.append(UInt32(state.currentBaseBasalRate * 1000).miniMedData())
        }
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
