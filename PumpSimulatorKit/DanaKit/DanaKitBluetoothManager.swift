import OSLog
import CoreBluetooth
import Foundation

class DanaKitBluetoothManager : NSObject {
    public var pumpManagerDelegate: DanaKitPumpManager?
    private let logger = PumpManagerLogger(subsystem: "com.bastiaanv.danaKit", category: "DanaKitBluetoothManager")
    
    private var manager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private let managerQueue = DispatchQueue(label: "com.DanaKit.bluetoothManagerQueue", qos: .unspecified)
    
    private let LOCAL_DEVICE_NAME = "MT"//"XXX00000XX"
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
    
    public func startAdvertising() {
        guard let peripheralManager = peripheralManager else {
            logger.error("No CBPeripheralManager available...")
            return
        }
        
        guard peripheralManager.state == .poweredOn else {
            logger.error("CBPeripheralManager is in an invalid state - state: \(peripheralManager.state.rawValue)")
            return
        }
        
        let advertisingData: [String : Any] = [
            CBAdvertisementDataLocalNameKey: LOCAL_DEVICE_NAME,
            CBAdvertisementDataServiceUUIDsKey: [SERVICE_UUID],
        ]
        
        peripheralManager.startAdvertising(advertisingData)
    }
    
    public func stopAdvertising() {
        guard let peripheralManager = peripheralManager, peripheralManager.isAdvertising else {
            return
        }
        
        peripheralManager.stopAdvertising()
    }
}

extension DanaKitBluetoothManager : CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("centralManagerDidUpdateState: \(central.state.rawValue)")
    }
}

extension DanaKitBluetoothManager : CBPeripheralManagerDelegate {
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: (any Error)?) {
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
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        if let error = error {
            logger.error("Got error during didAdd service - error: \(error.localizedDescription)")
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        logger.debug("Received subscription from \(central) on \(characteristic.uuid.uuidString)")
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for item in requests {
            guard item.characteristic.uuid == WRITE_CHAR_UUID else {
                logger.error("Received write on wrong characteristic - UUID: \(item.characteristic.uuid.uuidString), Service uuid: \(item.characteristic.service?.uuid.uuidString ?? "nil")")
                return
            }
            
            guard let pumpManager = pumpManagerDelegate else {
                logger.error("No pumpManagerDelegate")
                return
            }
            
            guard var value = item.value else {
                logger.warning("EMPTY data received - UUID: \(item.characteristic.uuid.uuidString), Service uuid: \(item.characteristic.service?.uuid.uuidString ?? "nil")")
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
            
            if isEncryptionCommand {
                processAuthMessage(peripheral, pumpManager, value)
            } else {
                processMessage(peripheral, pumpManager, value)
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
        
        switch data[4] {
        case DanaKitMessageType.OPCODE_ENCRYPTION__PUMP_CHECK:
            DanaKitAuthMessages.processPumpCheck(model)
            break
        case DanaKitMessageType.OPCODE_ENCRYPTION__TIME_INFORMATION:
            DanaKitAuthMessages.processTimeInformation(model)
            break
        default:
            logger.warning("Received unknown auth message - opCode: \(data[4])")
            return
        }
    }
    
    private func processMessage(_ peripheralManager: CBPeripheralManager, _ pumpManager: DanaKitPumpManager, _ data: Data) {
        let model = DanaKitProcessMessage(
            data: data,
            state: pumpManager.state,
            deviceName: LOCAL_DEVICE_NAME,
            writeParams: DanaKitWriteParams(
                characteristic: SUBSCRIPTION_CHARACTERISTIC,
                peripheralManager: peripheralManager
            )
        )
        
        switch data[4] {
        case DanaKitMessageType.OPCODE_ETC__KEEP_CONNECTION:
            DanaKitMessages.processKeepAlive(model)
            break
        case DanaKitMessageType.OPCODE_REVIEW__INITIAL_SCREEN_INFORMATION:
            DanaKitMessages.processInitialScreenInformation(model)
            break
        default:
            logger.warning("Received unknown message - opCode: \(data[4])")
            return
        }
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
    let deviceName: String
    let writeParams: DanaKitWriteParams
}

enum DanaKitMessages {
    static let logger = PumpManagerLogger(subsystem: "com.bastiaanv.danaKit", category: "DanaKitMessages")
}

enum DanaKitAuthMessages {
    static let logger = PumpManagerLogger(subsystem: "com.bastiaanv.danaKit", category: "DanaAuthMessages")
}
