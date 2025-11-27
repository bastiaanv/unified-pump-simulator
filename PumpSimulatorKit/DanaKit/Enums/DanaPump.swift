import Foundation
import SwiftUI

enum DanaPump: UInt8 {
    case DanaRSv1 = 0
    case DanaRSv3 = 1
    case DanaI = 2
    
    func getPumpModel() -> PumpModel {
        switch self {
        case .DanaRSv1:
            return PumpModel(name: "DanaRS v1", image: Image(imageName: "danars"), index: 0)
        case .DanaRSv3:
            return PumpModel(name: "DanaRS v3", image: Image(imageName: "danars"), index: 1)
        case .DanaI:
            return PumpModel(name: "Dana-I", image: Image(imageName: "danai"), index: 2)
        }
    }
    
    func getHardwareModel() -> UInt8 {
        switch self {
        case .DanaRSv1:
            return 0
        case .DanaRSv3:
            return 5
        case .DanaI:
            return 9
        }
    }
    
    func getProtocol() -> UInt8 {
        switch self {
        case .DanaRSv1:
            return 0
        case .DanaRSv3:
            return 0
        case .DanaI:
            return 19
        }
    }
    
    func getBle5Keys() -> Data {
        switch self {
        case .DanaRSv1:
            return Data([])
        case .DanaRSv3:
            // Starting random sync key
            return Data([0xDE])
        case .DanaI:
            // Just use a hardcoded key for simplicity
            return Data([0x39, 0x39, 0x35, 0x33, 0x38, 0x33])
        }
    }
    
    func getEncryptionKey() -> Data {
        if self != .DanaI {
            return Data([])
        }
        
        let ble5Key = self.getBle5Keys()
        let i1 = Int((ble5Key[0] - 0x30) * 10) &+ Int(ble5Key[1] - 0x30)
        let i2 = Int((ble5Key[2] - 0x30) * 10) &+ Int(ble5Key[3] - 0x30)
        let i3 = Int((ble5Key[4] - 0x30) * 10) &+ Int(ble5Key[5] - 0x30)

        return Data([
            secondLvlEncryptionLookupShort[Int(i1)],
            secondLvlEncryptionLookupShort[Int(i2)],
            secondLvlEncryptionLookupShort[Int(i3)]
        ])
    }
}
