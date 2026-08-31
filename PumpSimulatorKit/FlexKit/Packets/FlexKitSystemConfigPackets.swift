import Foundation

/// IDD System Configuration (`packets/05`). First wire byte is the opcode.
/// Implements the reads that map onto `MiniMedKitState` plus the
/// `WriteControllerData` CRC32 validation.
enum MiniMedKitSystemConfigPackets {
    static let logger = PumpManagerLogger(subsystem: "com.bastiaanv.minimedkit", category: "MiniMedKitSystemConfigPackets")

    static func process(_ payload: Data, _ params: MiniMedKitBluetoothManager.PacketParams) -> Bool {
        guard let op = payload.first else { return false }

        switch op {
        case 0x01: readConfiguration(payload, params)
            return true
        case 0x03: readBasalPattern(payload, params)
            return true
        case 0x05: readAvailableBasalPattern(params)
            return true
        case 0x0F: enterBg(payload, params)
            return true
        case 0x11: readHash(payload, params)
            return true
        case 0x15: writeControllerData(payload, params)
            return true
        case 0x17: readControllerData(payload, params)
            return true
        default: return false
        }
    }

    // MARK: - ReadConfiguration (0x01)

    // `[op u8][configurationType u8][status u8][ctx?][value …]` (`packets/05 §4.1`).

    private static func readConfiguration(_ payload: Data, _ params: MiniMedKitBluetoothManager.PacketParams) {
        guard payload.count >= 2 else { return }
        let type = payload[1]
        let state = params.pumpManager.state

        var body = Data()
        body.append(0x01) // op
        body.append(type) // configurationType
        body.append(0x01) // status (success)

        switch type {
        case 0: body.append(UInt32(state.maxBasal * 1000).miniMedData())
        case 1: body.append(UInt32(state.maxBolus * 1000).miniMedData())
        case 2:
            body.append(UInt8(state.carbRatio.count))
            for row in state.carbRatio {
                body.append(row.start.miniMedData())
                body.append(row.end.miniMedData()) }
        case 3:
            body.append(UInt8(state.isf.count))
            for row in state.isf {
                body.append(row.a.miniMedData())
                body.append(row.b.miniMedData()) }
        case 4:
            body.append(UInt8(state.bgTarget.count))
            for row in state.bgTarget {
                body.append(row.a.miniMedData())
                body.append(row.b.miniMedData())
                body.append(row.c.miniMedData()) }
        case 5: body.append(UInt16(state.activeInsulinTime / 60).miniMedData())
        case 6: body.append(0x00) // extended bolus delivery type flags
        default: body.append(0x00)
        }

        params.manager.sendCCMP(
            messageID: CcmpMsgID.commandControl.rawValue,
            payload: body,
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )
        logger.info("ReadConfiguration (type \(type))")
    }

    // MARK: - ReadBasalPattern (0x03)

    private static func readBasalPattern(_ payload: Data, _ params: MiniMedKitBluetoothManager.PacketParams) {
        let index = payload.count >= 2 ? payload[1] : 0
        let pattern = params.pumpManager.state.basalPatterns.first(where: { $0.id == index })

        var body = Data()
        body.append(0x03) // op
        body.append(index)
        body.append(0x01) // status
        for segment in pattern?.segments ?? [] {
            body.append(segment.duration.miniMedData())
            body.append(segment.rateMilliUnits.miniMedData())
        }
        params.manager.sendCCMP(
            messageID: CcmpMsgID.commandControl.rawValue,
            payload: body,
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )
    }

    // MARK: - ReadAvailableBasalPattern (0x05)

    // `[op u8][numberOfBasalPatterns u8][basalPatternIdFlags u8][activeBasalPatternId u8]`

    private static func readAvailableBasalPattern(_ params: MiniMedKitBluetoothManager.PacketParams) {
        let count = UInt8(min(params.pumpManager.state.basalPatterns.count, 0xFF))
        let body = Data([0x05, count, 0x00, 0x01])
        params.manager.sendCCMP(
            messageID: CcmpMsgID.commandControl.rawValue,
            payload: body,
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )
    }

    // MARK: - EnterBg (0x0F)

    // `[op 0x0F][bg u16][flag u8][timestamp u32][source u8]` → append a BG history record.

    private static func enterBg(_ payload: Data, _ params: MiniMedKitBluetoothManager.PacketParams) {
        guard payload.count >= 9 else { return }
        var record = Data()
        record.append(payload[1])
        record.append(payload[2])
        params.pumpManager.state.addHistory(type: 0x0001, data: record)
        params.pumpManager.notifyStateDidUpdate()

        // Simple header-only response `[op][status]`.
        params.manager.sendCCMP(
            messageID: CcmpMsgID.commandControl.rawValue,
            payload: Data([0x0F, 0x01]),
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )
        logger.info("EnterBg appended history record")
    }

    // MARK: - ReadHash (0x11)

    private static func readHash(_: Data, _ params: MiniMedKitBluetoothManager.PacketParams) {
        // `[op][status][count][hashContext u32][{hash u8}{value u32} ×count]`
        var body = Data([0x11, 0x01, 0x00])
        body.append(UInt32(0).miniMedData())
        params.manager.sendCCMP(
            messageID: CcmpMsgID.commandControl.rawValue,
            payload: body,
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )
    }

    // MARK: - WriteControllerData (0x15) — CRC32 validated.

    private static func writeControllerData(_ payload: Data, _ params: MiniMedKitBluetoothManager.PacketParams) {
        // `[op 0x15][len u8][payload …][crc32 u32 LE]`
        guard payload.count >= 6 else {
            respondWriteControllerData(status: 0x02, params: params)
            return
        }
        let declaredLen = Int(payload[1])
        // Payload = bytes from offset 2 up to 2+declaredLen (type + per-type fields).
        let crcStart = 2
        let crcEnd = crcStart + declaredLen
        guard crcEnd + 4 <= payload.count else {
            respondWriteControllerData(status: 0x02, params: params)
            return
        }
        let crcPayload = payload.subdata(in: crcStart ..< crcEnd)
        let expectedCRC = payload.miniMedUInt32(crcEnd)
        let actualCRC = Crc32.calculate(crcPayload)

        guard actualCRC == expectedCRC else {
            logger
                .warning(
                    "WriteControllerData CRC mismatch: got \(String(format: "%08x", expectedCRC)), expected \(String(format: "%08x", actualCRC))"
                )
            respondWriteControllerData(status: 0x02, params: params)
            return
        }

        respondWriteControllerData(status: 0x01, params: params)
        logger.info("WriteControllerData accepted (CRC ok)")
    }

    private static func respondWriteControllerData(status: UInt8, params: MiniMedKitBluetoothManager.PacketParams) {
        // `[op 0x15][status][ctx]`
        params.manager.sendCCMP(
            messageID: CcmpMsgID.commandControl.rawValue,
            payload: Data([0x15, status, 0x00]),
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )
    }

    // MARK: - ReadControllerData (0x17)

    private static func readControllerData(_ payload: Data, _ params: MiniMedKitBluetoothManager.PacketParams) {
        let type = payload.count >= 2 ? payload[1] : 0
        var body = Data([0x17, 0x01, type])
        let crc = Crc32.calculate(Data([type]))
        body.append(crc.miniMedData())
        params.manager.sendCCMP(
            messageID: CcmpMsgID.commandControl.rawValue,
            payload: body,
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )
    }
}
