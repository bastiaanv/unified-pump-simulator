import OSLog
import CoreBluetooth
import Foundation

class DanaKitBluetoothManager : NSObject {
    private let logger = Logger(subsystem: "com.bastiaanv.danaKit", category: "DanaKitBluetoothManager")
    
    private var manager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private let managerQueue = DispatchQueue(label: "com.DanaKit.bluetoothManagerQueue", qos: .unspecified)
    
    private let SERVICE_UUID = CBUUID(string: "FFF0")
    private let READ_CHAR_UUID = CBUUID(string: "FFF1")
    private let WRITE_CHAR_UUID = CBUUID(string: "FFF2")
    
    override init() {
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
            CBAdvertisementDataLocalNameKey:"VJX00016FI"
        ]
        
        peripheralManager.startAdvertising(advertisingData)
    }
    
    public func stopAdvertising() {
        peripheralManager?.stopAdvertising()
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
        
        logger.info("Peripheral started advertising!")
    }
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        logger.info("peripheralManagerDidUpdateState: \(peripheral.state.rawValue)")
        guard peripheral.state == .poweredOn else {
            return
        }
        
        let service = CBMutableService(type: SERVICE_UUID, primary: true)
        service.characteristics = [
            CBMutableCharacteristic(
                type: READ_CHAR_UUID,
                properties: [.indicate, .notify],
                value: nil,
                permissions: .readable
            ),
            CBMutableCharacteristic(
                type: WRITE_CHAR_UUID,
                properties: [.writeWithoutResponse],
                value: nil,
                permissions: .writeable
            )
        ]
        
        peripheral.add(service)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        if let error = error {
            logger.error("Got error during didAdd service - error: \(error.localizedDescription)")
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for item in requests {
            guard item.characteristic.uuid == WRITE_CHAR_UUID else {
                logger.error("Received write on wrong characteristic - UUID: \(item.characteristic.uuid.uuidString), Service uuid: \(item.characteristic.service?.uuid.uuidString ?? "nil")")
                return
            }
            
            guard let value = item.value else {
                logger.warning("EMPTY data received - UUID: \(item.characteristic.uuid.uuidString), Service uuid: \(item.characteristic.service?.uuid.uuidString ?? "nil")")
                return
            }
            
            logger.debug("Received message: \(value.hexString())")
            processMessage(value)
        }
    }
}

extension DanaKitBluetoothManager {
    private func processMessage(_ data: Data) {}
}
