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

        logger.info("Received message: \(data.hexString())")

        let param = MedtrumKitPackets.MedtrumKitPacketRequest(
            data: data,
            pumpManager: pumpManager,
            responseParam: WriteResponseParam(
                responseCode: data[1],
                messageId: data[2],
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
        default:
            logger.warning("Received unknown command: \(data[1])")
        }

        peripheralManager.respond(to: request, withResult: .success)
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
