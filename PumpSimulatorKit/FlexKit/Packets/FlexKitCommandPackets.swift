import Foundation

/// IDD Command Control handlers (`packets/03` requests / `packets/04` responses).
/// Implements the two commands that matter most to the UI: **bolus** and
/// **suspend/resume**, plus a temp-basal stub.
///
/// The real phone drives each command through a transaction
/// (initiate → set-params → confirm). Tier A keeps framing/interop simple: an
/// inbound *bolus param* frame (layout `[type<<1 u8][normal mU u32][square mU u32]
/// [squareDur u16][0x02]`, `packets/03 §2.4`) starts a simulated delivery, and the
/// pump emits accept + command-result responses.
enum MiniMedKitCommandPackets {
    static let logger = PumpManagerLogger(subsystem: "com.bastiaanv.minimedkit", category: "MiniMedKitCommandPackets")

    static var bolusTimer: Timer?
    private static var currentTransaction: UInt16 = 0

    static func process(messageID _: UInt16, payload: Data, params: MiniMedKitBluetoothManager.PacketParams) {
        // Suspend / resume (very light heuristics — opcode byte 0x04 = cancel in the
        // command-control response space; treated here as suspend). Kept explicit so
        // a real capture can be wired in later.
        if payload == Data([0x04, 0x00, 0x00, 0x00]) || payload == Data([0x02]) {
            suspendPump(params)
            return
        }

        // Bolus parameter frame (>= 12 bytes with activation-type byte `0x02` at [11]).
        if payload.count >= 12, payload[11] == 0x02 {
            startBolus(payload, params)
            return
        }

        // Unknown command — protocol error (opcode ≥ 9, 2 bytes).
        params.manager.sendCCMP(
            messageID: CcmpMsgID.commandControl.rawValue,
            payload: Data([0x09, 0x01]),
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )
        logger.info("Unhandled command-control message")
    }

    // MARK: - Bolus

    private static func startBolus(_ payload: Data, _ params: MiniMedKitBluetoothManager.PacketParams) {
        let pumpManager = params.pumpManager
        let normalMU = payload.miniMedUInt32(1)
        let amount = Double(normalMU) / 1000.0

        guard amount > 0 else {
            sendProtocolError(params)
            return
        }

        currentTransaction &+= 1
        let txnId = currentTransaction

        // Respond: accept transaction (opcode 1) + parameter-result (opcode 6).
        var accept = Data()
        accept.append(0x01)
        accept.append(txnId.miniMedData())
        accept.append(0x0C) // bolus command type
        accept.append(UInt32(Date().timeIntervalSince1970).miniMedData())
        accept.append(UInt16(60).miniMedData()) // timeout
        accept.append(UInt16(0).miniMedData()) // glucose
        accept.append(UInt32(0).miniMedData()) // active insulin
        accept.append(0x00) // flags
        accept.append(UInt32(pumpManager.state.maxBolus * 1000).miniMedData())
        accept.append(UInt16(0).miniMedData())
        accept.append(UInt32(pumpManager.state.reservoirLevel * 1000).miniMedData())
        accept.append(UInt32(0).miniMedData())

        params.manager.sendCCMP(
            messageID: CcmpMsgID.commandControl.rawValue,
            payload: accept,
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )

        var paramResult = Data()
        paramResult.append(0x06)
        paramResult.append(txnId.miniMedData())
        paramResult.append(0x0C)
        paramResult.append(0x01) // status success
        paramResult.append(0x00) // sequence
        paramResult.append(UInt32(0).miniMedData())
        paramResult.append(0x00)
        paramResult.append(UInt32(0).miniMedData()) // active insulin
        params.manager.sendCCMP(
            messageID: CcmpMsgID.commandControl.rawValue,
            payload: paramResult,
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )

        // Command result (confirm) with bolusId.
        var confirm = Data()
        confirm.append(0x08)
        confirm.append(txnId.miniMedData())
        confirm.append(0x0C)
        confirm.append(0x01) // status success
        confirm.append(txnId.miniMedData()) // bolusId u16
        params.manager.sendCCMP(
            messageID: CcmpMsgID.commandControl.rawValue,
            payload: confirm,
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )

        scheduleBolus(amount: amount, pumpManager: pumpManager, params: params)
        logger.info("Started bolus of \(amount) U")
    }

    private static func scheduleBolus(
        amount: Double,
        pumpManager: MiniMedKitPumpManager,
        params _: MiniMedKitBluetoothManager.PacketParams
    ) {
        // 1.5 U per minute (matches the Medtrum simulator's delivery model).
        let duration = amount / 1.5 * TimeInterval.minutes(1)
        let startTime = Date.now
        let endTime = startTime.addingTimeInterval(duration)
        let originalReservoir = pumpManager.state.reservoirLevel

        pumpManager.state.bolusTotal = amount
        pumpManager.state.bolusProgress = 0
        pumpManager.notifyStateDidUpdate()

        DispatchQueue.main.async {
            bolusTimer?.invalidate()
            bolusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                let progressPercentage = Date.now.timeIntervalSince(startTime) / endTime.timeIntervalSince(startTime)
                let progress = min(amount, amount * progressPercentage)

                pumpManager.state.reservoirLevel = max(0, originalReservoir - progress)
                pumpManager.state.bolusProgress = progress
                pumpManager.notifyStateDidUpdate()

                if progressPercentage >= 1.0 {
                    bolusTimer?.invalidate()
                    bolusTimer = nil
                    pumpManager.state.bolusTotal = nil
                    pumpManager.state.bolusProgress = nil
                    pumpManager.state.addHistory(type: 0x0002, data: UInt32(amount * 1000).miniMedData())
                    pumpManager.notifyStateDidUpdate()
                }
            }
        }
    }

    // MARK: - Suspend

    private static func suspendPump(_ params: MiniMedKitBluetoothManager.PacketParams) {
        let state = params.pumpManager.state
        if state.suspendedSince == nil {
            state.suspendedSince = Date.now
        } else {
            state.suspendedSince = nil
        }
        params.pumpManager.notifyStateDidUpdate()

        params.manager.sendCCMP(
            messageID: CcmpMsgID.commandControl.rawValue,
            payload: Data([0x04, 0x00, 0x00, 0x01]),
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )
        logger.info("Toggled suspend/resume")
    }

    private static func sendProtocolError(_ params: MiniMedKitBluetoothManager.PacketParams) {
        params.manager.sendCCMP(
            messageID: CcmpMsgID.commandControl.rawValue,
            payload: Data([0x09, 0x01]),
            to: params.manager.data7102,
            peripheralManager: params.peripheralManager
        )
    }
}
