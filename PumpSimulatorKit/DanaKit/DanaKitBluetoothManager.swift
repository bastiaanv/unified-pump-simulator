import CoreBluetooth
import Foundation
import OSLog

class DanaKitBluetoothManager: NSObject {
    var pumpManagerDelegate: DanaKitPumpManager?
    private let logger = PumpManagerLogger(subsystem: "com.bastiaanv.danaKit", category: "DanaKitBluetoothManager")

    private var manager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private let managerQueue = DispatchQueue(label: "com.DanaKit.bluetoothManagerQueue", qos: .unspecified)

    let LOCAL_DEVICE_NAME = "VJX00016FI" // "XXX00000XX"
    private let SERVICE_UUID = CBUUID(string: "FFF0")
    private let SUBSCRIPTION_CHAR_UUID = CBUUID(string: "FFF1")
    private var SUBSCRIPTION_CHARACTERISTIC: CBMutableCharacteristic
    private let WRITE_CHAR_UUID = CBUUID(string: "FFF2")
    private let WRITE_CHARACTERISTIC: CBMutableCharacteristic

    override init() {
        WRITE_CHARACTERISTIC = CBMutableCharacteristic(
            type: WRITE_CHAR_UUID,
            properties: [.writeWithoutResponse],
            value: nil,
            permissions: .writeable
        )

        SUBSCRIPTION_CHARACTERISTIC = CBMutableCharacteristic(
            type: SUBSCRIPTION_CHAR_UUID,
            properties: [.indicate, .notify],
            value: nil,
            permissions: .readable
        )
        super.init()

        managerQueue.sync {
            self.manager = CBCentralManager(delegate: self, queue: managerQueue)
            self.peripheralManager = CBPeripheralManager(delegate: self, queue: managerQueue)
        }
    }

    func startAdvertising() {
        guard let peripheralManager = peripheralManager else {
            logger.error("No CBPeripheralManager available...")
            return
        }

        guard peripheralManager.state == .poweredOn else {
            logger.error("CBPeripheralManager is in an invalid state - state: \(peripheralManager.state.rawValue)")
            return
        }

        let advertisingData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: LOCAL_DEVICE_NAME,
            CBAdvertisementDataServiceUUIDsKey: [SERVICE_UUID],
        ]

        peripheralManager.startAdvertising(advertisingData)
    }

    func stopAdvertising() {
        guard let peripheralManager = peripheralManager, peripheralManager.isAdvertising else {
            return
        }

        peripheralManager.stopAdvertising()
    }
}

extension DanaKitBluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("centralManagerDidUpdateState: \(central.state.rawValue)")
    }
}

extension DanaKitBluetoothManager: CBPeripheralManagerDelegate {
    func peripheralManagerDidStartAdvertising(_: CBPeripheralManager, error: (any Error)?) {
        if let error = error {
            logger.error("Failed to start advertising: \(error.localizedDescription)")
            return
        }

        logger.info("Simulator has started!")
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        logger.info("peripheralManagerDidUpdateState: \(peripheral.state.rawValue)")
        guard peripheral.state == .poweredOn else {
            return
        }

        peripheral.removeAllServices()

        let service = CBMutableService(type: SERVICE_UUID, primary: true)
        service.characteristics = [SUBSCRIPTION_CHARACTERISTIC, WRITE_CHARACTERISTIC]
        peripheral.add(service)
    }

    func peripheralManager(_: CBPeripheralManager, didAdd _: CBService, error: (any Error)?) {
        if let error = error {
            logger.error("Got error during didAdd service - error: \(error.localizedDescription)")
        }
    }

    func peripheralManager(_: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        logger.debug("Received subscription from \(central) on \(characteristic.uuid.uuidString)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for item in requests {
            guard item.characteristic.uuid == WRITE_CHAR_UUID else {
                let message = "Received write on wrong characteristic - UUID: \(item.characteristic.uuid.uuidString), Service uuid: \(item.characteristic.service?.uuid.uuidString ?? "nil")"
                logger.error(message)
                return
            }

            guard let pumpManager = pumpManagerDelegate else {
                logger.error("No pumpManagerDelegate")
                return
            }

            guard var value = item.value else {
                let message = "EMPTY data received - UUID: \(item.characteristic.uuid.uuidString), Service uuid: \(item.characteristic.service?.uuid.uuidString ?? "nil")"
                logger.warning(message)
                return
            }

            let isEncryptionCommand = value[0] == 0xA5
            if value[0] != 0xA5 {
                value = DanaKitEncryption.decrypt(data: value, state: pumpManager.state)
                logger.debug("Second decryption: \(value.hexString())")
            }

            value = DanaKitEncryption.xorPacketSerialNumber(data: value, deviceName: LOCAL_DEVICE_NAME)
            logger.debug("Received message: \(value.hexString())")

            let expectedCrc = DanaKitEncryption.generateCrc(
                buffer: value.subdata(in: 3 ..< value.count - 4),
                enhancedEncryption: pumpManager.state.pumpModel,
                isEncryptionCommand: isEncryptionCommand
            )

            let actualCrc = UInt16(value[value.count - 4]) << 8 + UInt16(value[value.count - 3])
            guard expectedCrc == actualCrc else {
                logger.error("Crc check failed - actualCrc: \(actualCrc), expectedCrc: \(expectedCrc)")
                return
            }

            let data = value.subdata(in: 3 ..< value.count - 2)
            if isEncryptionCommand {
                processAuthMessage(peripheral, pumpManager, data)
            } else {
                processMessage(peripheral, pumpManager, data)
            }
        }
    }
}

extension DanaKitBluetoothManager {
    private func processAuthMessage(_ peripheralManager: CBPeripheralManager, _ pumpManager: DanaKitPumpManager, _ data: Data) {
        let model = DanaKitProcessAuthMessage(
            data: data,
            pump: pumpManager.state.pumpModel,
            deviceName: LOCAL_DEVICE_NAME,
            writeParams: DanaKitWriteParams(
                characteristic: SUBSCRIPTION_CHARACTERISTIC,
                peripheralManager: peripheralManager
            )
        )

        switch data[1] {
        case DanaKitMessageType.OPCODE_ENCRYPTION__PUMP_CHECK:
            DanaKitAuthMessages.processPumpCheck(model)
        case DanaKitMessageType.OPCODE_ENCRYPTION__TIME_INFORMATION:
            DanaKitAuthMessages.processTimeInformation(model)
        default:
            logger.warning("Received unknown auth message - opCode: \(data[4])")
            return
        }
    }

    private func processMessage(_ peripheralManager: CBPeripheralManager, _ pumpManager: DanaKitPumpManager, _ data: Data) {
        let model = DanaKitProcessMessage(
            data: data,
            state: pumpManager.state,
            pumpManager: pumpManager,
            deviceName: LOCAL_DEVICE_NAME,
            writeParams: DanaKitWriteParams(
                characteristic: SUBSCRIPTION_CHARACTERISTIC,
                peripheralManager: peripheralManager
            )
        )

        switch data[1] {
        case DanaKitMessageType.OPCODE_ETC__KEEP_CONNECTION:
            DanaKitMessages.processKeepAlive(model)
        case DanaKitMessageType.OPCODE_REVIEW__INITIAL_SCREEN_INFORMATION:
            DanaKitMessages.processInitialScreenInformation(model)
        case DanaKitMessageType.OPCODE_OPTION__GET_PUMP_TIME:
            DanaKitMessages.processGetTime(model)
        case DanaKitMessageType.OPCODE_OPTION__GET_PUMP_UTC_AND_TIME_ZONE:
            DanaKitMessages.processGetTimeWithUtc(model)
        case DanaKitMessageType.OPCODE_OPTION__SET_PUMP_TIME:
            DanaKitMessages.processSetTime(model)
        case DanaKitMessageType.OPCODE_OPTION__SET_PUMP_UTC_AND_TIME_ZONE:
            DanaKitMessages.processSetTimeWithUtc(model)
        case DanaKitMessageType.OPCODE_OPTION__GET_USER_OPTION:
            DanaKitMessages.processGetUserOptions(model)
        case DanaKitMessageType.OPCODE_OPTION__SET_USER_OPTION:
            DanaKitMessages.processSetUserOptions(model)
        case DanaKitMessageType.OPCODE_REVIEW__SET_HISTORY_UPLOAD_MODE:
            DanaKitMessages.processHistoryMode(model)
        case DanaKitMessageType.OPCODE_REVIEW__ALARM,
             DanaKitMessageType.OPCODE_REVIEW__ALL_HISTORY,
             DanaKitMessageType.OPCODE_REVIEW__BASAL,
             DanaKitMessageType.OPCODE_REVIEW__BLOOD_GLUCOSE,
             DanaKitMessageType.OPCODE_REVIEW__BOLUS,
             DanaKitMessageType.OPCODE_REVIEW__BOLUS_AVG,
             DanaKitMessageType.OPCODE_REVIEW__CARBOHYDRATE,
             DanaKitMessageType.OPCODE_REVIEW__DAILY,
             DanaKitMessageType.OPCODE_REVIEW__PRIME,
             DanaKitMessageType.OPCODE_REVIEW__REFILL,
             DanaKitMessageType.OPCODE_REVIEW__SUSPEND,
             DanaKitMessageType.OPCODE_REVIEW__TEMPORARY:
            DanaKitMessages.processHistory(model)
        case DanaKitMessageType.OPCODE_BOLUS__SET_STEP_BOLUS_START:
            DanaKitMessages.processStartBolus(model)
        case DanaKitMessageType.OPCODE_BOLUS__SET_STEP_BOLUS_STOP:
            DanaKitMessages.processStopBolus(model)
        case DanaKitMessageType.OPCODE_BASAL__APS_SET_TEMPORARY_BASAL,
             DanaKitMessageType.OPCODE_BASAL__SET_TEMPORARY_BASAL:
            DanaKitMessages.processTempBasalStart(model)
        case DanaKitMessageType.OPCODE_BASAL__CANCEL_TEMPORARY_BASAL:
            DanaKitMessages.processTempBasalEnd(model)
        case DanaKitMessageType.OPCODE_BASAL__SET_SUSPEND_ON:
            DanaKitMessages.processSuspend(model)
        case DanaKitMessageType.OPCODE_BASAL__SET_SUSPEND_OFF:
            DanaKitMessages.processResume(model)
        default:
            logger.warning("Received unknown message - opCode: \(data[1])")
            return
        }

        pumpManager.notifyStateUpdate()
    }
}

struct DanaKitProcessAuthMessage {
    let data: Data
    let pump: DanaPump
    let deviceName: String
    let writeParams: DanaKitWriteParams
}

struct DanaKitProcessMessage {
    let data: Data
    let state: DanaKitState
    let pumpManager: DanaKitPumpManager
    let deviceName: String
    let writeParams: DanaKitWriteParams
}

enum DanaKitMessages {
    static let logger = PumpManagerLogger(subsystem: "com.bastiaanv.danaKit", category: "DanaKitMessages")
}

enum DanaKitAuthMessages {
    static let logger = PumpManagerLogger(subsystem: "com.bastiaanv.danaKit", category: "DanaAuthMessages")
}
