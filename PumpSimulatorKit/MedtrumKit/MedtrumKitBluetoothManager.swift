import CoreBluetooth

class MedtrumKitBluetoothManager {
    var pumpManagerDelegate: MedtrumKitPumpManager?
    let logger = PumpManagerLogger(subsystem: "com.bastiaanv.medtrumkit", category: "MedtrumKitBluetoothManager")
    let pumpBluetoothManager: PumpBluetoothmanager

    private let SERVICE_UUID = CBUUID(string: "669A9001-0008-968F-E311-6050405558B3")
    private let SUBSCRIPTION_CHAR_UUID = CBUUID(string: "669a9120-0008-968f-e311-6050405558b3")
    private var SUBSCRIPTION_CHARACTERISTIC: CBMutableCharacteristic
    private let WRITE_CHAR_UUID = CBUUID(string: "669a9101-0008-968f-e311-6050405558b3")
    private let WRITE_CHARACTERISTIC: CBMutableCharacteristic

    /// The connected phones, by the characteristics each subscribed to
    var subscriptions: [UUID: Set<CBUUID>] = [:]
    var writeQueue: [(Data, CBMutableCharacteristic)] = []
    var buffer = Data()

    /// The fault armed for the command being executed - see `MedtrumKitBluetoothManager+Faults.swift`
    var commandFault: PendingCommandFault?
    /// The command answered last, and how: whether a halt armed on it applies (`haltAfter`)
    var lastAnswer: (command: UInt8, status: ResponseStatus)?
    /// The link is silent for a fault until then: nothing goes out, what comes in is lost
    var linkSilentUntil: Date?
    var isLinkSilent: Bool {
        linkSilentUntil != nil
    }

    /// Goes up as a connection starts and ends, at Start, Stop and Reset Pump: a late answer is sent in the session it
    /// was held back in only
    var session = 0

    init(pumpBluetoothManager: PumpBluetoothmanager) {
        WRITE_CHARACTERISTIC = CBMutableCharacteristic(
            type: WRITE_CHAR_UUID,
            properties: [.indicate, .notify, .write],
            value: nil,
            permissions: .writeable
        )

        SUBSCRIPTION_CHARACTERISTIC = CBMutableCharacteristic(
            type: SUBSCRIPTION_CHAR_UUID,
            properties: [.indicate, .notify],
            value: nil,
            permissions: .writeable
        )
        self.pumpBluetoothManager = pumpBluetoothManager
    }

    func startAdvertising() {
        pumpBluetoothManager.bluetoothManagerDelegate = self
        session += 1

        let service = CBMutableService(type: SERVICE_UUID, primary: true)
        service.characteristics = [SUBSCRIPTION_CHARACTERISTIC, WRITE_CHARACTERISTIC]

        let advertisingData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: "MT",
            CBAdvertisementDataServiceUUIDsKey: [],
        ]

        pumpBluetoothManager.startAdvertising(services: [service], advertisingData: advertisingData)
    }

    func stopAdvertising() {
        pumpBluetoothManager.stopAdvertising()
        MedtrumKitPackets.unscheduleUpdates()

        subscriptions.removeAll()
        endSession()
    }

    /// Nothing from before goes out after this: what is queued and a pending command fault are dropped, a silent link
    /// ends, and a late answer held back is dropped when due (`session`). At Stop and Reset Pump.
    func endSession() {
        writeQueue.removeAll()
        buffer = Data()
        commandFault = nil
        linkSilentUntil = nil
        session += 1
    }

    /// The phone is gone: what was queued for it is dropped, a late answer held back for it is dropped when due. A
    /// silent link goes on - it is the radio's, not the connection's.
    private func endConnection(_ reason: String) {
        MedtrumKitPackets.unscheduleUpdates()
        subscriptions.removeAll()
        if !writeQueue.isEmpty {
            logger.info("\(reason): \(writeQueue.count) queued write(s) dropped")
        } else {
            logger.info(reason)
        }
        writeQueue.removeAll()
        buffer = Data()
        session += 1
    }
}

extension MedtrumKitBluetoothManager: BluetoothManagerDelegate {
    func didStartAdvertising(_ error: (any Error)?) {
        if let error = error {
            logger.error("Failed to start advertising: \(error.localizedDescription)")
            return
        }

        logger.info("Medtrum simulator has started!")
    }

    func didReceiveWrite(
        _ peripheralManager: CBPeripheralManager,
        characteristic: CBCharacteristic,
        data: Data,
        request: CBATTRequest
    ) {
        guard characteristic.uuid == WRITE_CHAR_UUID else {
            let message = "Received write on wrong characteristic - UUID: \(characteristic.uuid.uuidString), Service uuid: \(characteristic.service?.uuid.uuidString ?? "nil")"
            logger.error(message)
            return
        }

        guard let pumpManager = pumpManagerDelegate else {
            logger.error("No pumpManagerDelegate")
            return
        }

        if buffer.isEmpty {
            buffer.append(data.subdata(in: 0 ..< data.count - 1))
        } else {
            buffer.append(data[4 ..< data.count - 1])
        }

        if buffer[0] != buffer.count {
            logger.info("Message not complete...")
            peripheralManager.respond(to: request, withResult: .success)

            return
        }

        logger.info("Received message: \(buffer.hexString())")
        let command = buffer[1]

        // The link is silent for a fault: what the phone sends never arrives
        if isLinkSilent {
            logger.warning("[FAULT] Link silent: \(MedtrumKitCommandFaults.name(of: command)) lost, not executed")
            peripheralManager.respond(to: request, withResult: .success)
            buffer = Data()
            return
        }
        let param = MedtrumKitPackets.MedtrumKitPacketRequest(
            data: buffer,
            pumpManager: pumpManager,
            responseParam: WriteResponseParam(
                responseCode: buffer[1],
                messageId: buffer[2],
                characteristic: WRITE_CHARACTERISTIC,
                peripheralManager: peripheralManager
            ),
            updateParam: WriteResponseParam(
                responseCode: 0,
                messageId: 0,
                characteristic: SUBSCRIPTION_CHARACTERISTIC,
                peripheralManager: peripheralManager
            )
        )

        // Temp basals and suspends that ran out, midnights passed: before the command acts on them
        pumpManager.advanceDelivery()

        guard !takeNotExecutedFault(for: command) else {
            peripheralManager.respond(to: request, withResult: .success)
            buffer = Data()
            return
        }

        let halt = armHalt(for: command)
        if halt == nil {
            armFault(for: command)
        }
        lastAnswer = nil
        dispatch(command, param)
        finishCommandFault()
        if let halt {
            haltAfter(command, halt)
        }

        peripheralManager.respond(to: request, withResult: .success)
        buffer = Data()
    }

    private func dispatch(_ command: UInt8, _ param: MedtrumKitPackets.MedtrumKitPacketRequest) {
        switch command {
        case CommandType.SYNCHRONIZE:
            MedtrumKitPackets.parseSynchronizePacket(param, self)
        case CommandType.AUTH_REQ:
            MedtrumKitPackets.parseAuthorizePacket(param, self)
        case CommandType.SUBSCRIBE:
            MedtrumKitPackets.parseSubscribePacket(param, self)
        case CommandType.PRIME:
            MedtrumKitPackets.parsePrimePacket(param, self)
        case CommandType.ACTIVATE:
            MedtrumKitPackets.parseActivatePacket(param, self)
        case CommandType.SET_TIME:
            MedtrumKitPackets.parseSetTime(param, self)
        case CommandType.GET_TIME:
            MedtrumKitPackets.parseGetTime(param, self)
        case CommandType.SET_TIME_ZONE:
            MedtrumKitPackets.parseSetTimeZone(param, self)
        case CommandType.SUSPEND_PUMP:
            MedtrumKitPackets.parseSuspendPacket(param, self)
        case CommandType.RESUME_PUMP:
            MedtrumKitPackets.parseResumePacket(param, self)
        case CommandType.STOP_PATCH:
            MedtrumKitPackets.parseDeactivatePacket(param, self)
        case CommandType.SET_TEMP_BASAL:
            MedtrumKitPackets.parseTempBasalPacket(param, self)
        case CommandType.CANCEL_TEMP_BASAL:
            MedtrumKitPackets.parseStopTempBasalPacket(param, self)
        case CommandType.CLEAR_ALARM:
            MedtrumKitPackets.parseClearAlertPacket(param, self)
        case CommandType.SET_PATCH:
            MedtrumKitPackets.parseSetPatchPacket(param, self)
        case CommandType.SET_BASAL_PROFILE:
            MedtrumKitPackets.parseBasalSchedulePacket(param, self)
        case CommandType.SET_BOLUS:
            MedtrumKitPackets.startBolus(param, self)
        case CommandType.CANCEL_BOLUS:
            MedtrumKitPackets.stopBolus(param, self)
        case CommandType.GET_RECORD:
            MedtrumKitPackets.parseGetRecordPacket(param, self)
        default:
            logger.warning("Received unknown command: \(command)")
        }
    }

    func readyForNextMessage(_ peripheral: CBPeripheralManager) {
        guard let item = writeQueue.first else {
            return
        }

        // A real patch keeps nothing for a phone that is gone
        guard let centrals = item.1.subscribedCentrals, !centrals.isEmpty else {
            logger.error("Cannot write value to device -> No subscribed centrals: \(writeQueue.count) write(s) dropped")
            writeQueue.removeAll()
            return
        }

        logger.info("Writing: \(item.0.hexString()), to: \(item.1.uuid.uuidString)")
        if let shortest = centrals.map(\.maximumUpdateValueLength).min(), item.0.count > shortest {
            logger.warning("Writing \(item.0.count) bytes, more than the central takes at once (\(shortest))")
        }
        guard peripheral.updateValue(item.0, for: item.1, onSubscribedCentrals: centrals) else {
            return
        }

        writeQueue.removeFirst()
        readyForNextMessage(peripheral)
    }

    func didReceiveSubscribe(central: CBCentral, to characteristic: CBCharacteristic, peripheralManager: CBPeripheralManager) {
        // Subscribed to it already: the connection it did that on ended without CoreBluetooth telling
        if subscriptions[central.identifier]?.contains(characteristic.uuid) == true {
            endConnection("The phone subscribed again, its last connection is over")
        }

        let isNewCentral = subscriptions[central.identifier] == nil
        if subscriptions.isEmpty {
            // A new connection
            session += 1
        }
        subscriptions[central.identifier, default: []].insert(characteristic.uuid)

        if isNewCentral, let pumpManager = pumpManagerDelegate {
            let param = MedtrumKitPackets.MedtrumKitPacketRequest(
                data: buffer,
                pumpManager: pumpManager,
                responseParam: WriteResponseParam(
                    responseCode: 0,
                    messageId: 0,
                    characteristic: WRITE_CHARACTERISTIC,
                    peripheralManager: peripheralManager
                ),
                updateParam: WriteResponseParam(
                    responseCode: 0,
                    messageId: 0,
                    characteristic: SUBSCRIPTION_CHARACTERISTIC,
                    peripheralManager: peripheralManager
                )
            )

            MedtrumKitPackets.scheduleUpdates(param, self)
        }
    }

    func didUnsubscribe(central: CBCentral) {
        guard subscriptions.removeValue(forKey: central.identifier) != nil else {
            return
        }

        if subscriptions.isEmpty {
            endConnection("The phone unsubscribed")
        }
    }

    func didUpdateState(_ state: CBManagerState) {
        // Below powered on, every phone has been disconnected - CoreBluetooth may not say so per phone
        guard state != .poweredOn, !subscriptions.isEmpty || !writeQueue.isEmpty else {
            return
        }

        endConnection("Bluetooth is no longer on (state \(state.rawValue)), the phone is disconnected")
    }
}

enum MedtrumKitPackets {
    static let logger = PumpManagerLogger(subsystem: "com.bastiaanv.medtrumkit", category: "MedtrumKitPackets")

    struct MedtrumKitPacketRequest {
        let data: Data
        let pumpManager: MedtrumKitPumpManager
        let responseParam: MedtrumKitBluetoothManager.WriteResponseParam
        let updateParam: MedtrumKitBluetoothManager.WriteResponseParam
    }
}
