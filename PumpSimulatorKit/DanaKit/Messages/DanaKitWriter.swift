import CoreBluetooth
import Foundation

enum DanaKitWriter {
    static let logger = PumpManagerLogger(subsystem: "com.bastiaanv.danaKit", category: "DanaKitWriter")
    
    static func write(_ data: Data, _ params: DanaKitWriteParams) {
        guard let centrals = params.characteristic.subscribedCentrals, !centrals.isEmpty else {
            logger.error("Cannot write value to device -> No subscribed centrals...")
            return
        }
        
        params.peripheralManager.updateValue(data, for: params.characteristic, onSubscribedCentrals: centrals)
    }
}

struct DanaKitWriteParams {
    let characteristic: CBMutableCharacteristic
    let peripheralManager: CBPeripheralManager
}
