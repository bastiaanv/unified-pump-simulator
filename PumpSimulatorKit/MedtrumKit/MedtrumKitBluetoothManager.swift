import CoreBluetooth

class MedtrumKitBluetoothManager {
    var pumpManagerDelegate: MedtrumKitPumpManager?
    let logger = PumpManagerLogger(subsystem: "com.bastiaanv.medtrumkit", category: "MedtrumKitBluetoothManager")
    private let pumpBluetoothManager: PumpBluetoothmanager

    private let SERVICE_UUID = CBUUID(string: "669A9001-0008-968F-E311-6050405558B3")
    private let SUBSCRIPTION_CHAR_UUID = CBUUID(string: "669a9120-0008-968f-e311-6050405558b3")
    private var SUBSCRIPTION_CHARACTERISTIC: CBMutableCharacteristic
    private let WRITE_CHAR_UUID = CBUUID(string: "669a9101-0008-968f-e311-6050405558b3")
    private let WRITE_CHARACTERISTIC: CBMutableCharacteristic

    var subscribedCentrals: [CBCentral] = []
    var writeQueue: [(Data, CBMutableCharacteristic)] = []
    private var buffer = Data()

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

        let service = CBMutableService(type: SERVICE_UUID, primary: true)
        service.characteristics = [SUBSCRIPTION_CHARACTERISTIC, WRITE_CHARACTERISTIC]

        let advertisingData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: "MT",
            CBAdvertisementDataServiceUUIDsKey: [SERVICE_UUID],
        ]

        pumpBluetoothManager.startAdvertising(services: [service], advertisingData: advertisingData)
    }

    func stopAdvertising() {
        pumpBluetoothManager.stopAdvertising()
        MedtrumKitPackets.unscheduleUpdates()

        subscribedCentrals.removeAll()
        writeQueue.removeAll()
        buffer = Data()
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

        switch data[1] {
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
        case CommandType.SET_BASAL_PROFILE:
            MedtrumKitPackets.parseBasalSchedulePacket(param, self)
        case CommandType.SET_BOLUS:
            MedtrumKitPackets.startBolus(param, self)
        case CommandType.CANCEL_BOLUS:
            MedtrumKitPackets.stopBolus(param, self)
        default:
            logger.warning("Received unknown command: \(buffer[1])")
        }

        peripheralManager.respond(to: request, withResult: .success)
        buffer = Data()
    }

    func readyForNextMessage(_ peripheral: CBPeripheralManager) {
        guard let item = writeQueue.first else {
            return
        }

        guard let centrals = item.1.subscribedCentrals, !centrals.isEmpty else {
            logger.error("Cannot write value to device -> No subscribed centrals...")
            return
        }

        logger.info("Writing: \(item.0.hexString()), to: \(item.1.uuid.uuidString)")
        guard peripheral.updateValue(item.0, for: item.1, onSubscribedCentrals: centrals) else {
            return
        }

        writeQueue.removeFirst()
        readyForNextMessage(peripheral)
    }

    func didReceiveSubscribe(central: CBCentral, peripheralManager: CBPeripheralManager) {
        if subscribedCentrals.contains(central) {
            return
        }

        subscribedCentrals.append(central)
        if let pumpManager = pumpManagerDelegate, pumpManager.state.patchState == .active {
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
        guard let index = subscribedCentrals.firstIndex(of: central) else {
            return
        }

        subscribedCentrals.remove(at: index)
        if subscribedCentrals.isEmpty {
            MedtrumKitPackets.unscheduleUpdates()
        }
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
