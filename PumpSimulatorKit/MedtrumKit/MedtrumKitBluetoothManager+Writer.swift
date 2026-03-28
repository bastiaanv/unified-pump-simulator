import CoreBluetooth
import Foundation

enum ResponseStatus: UInt16 {
    case ok = 0x0000
    case invalidState = 0x0008

    case stateUpdate = 0xFFFF
}

extension MedtrumKitBluetoothManager {
    public struct WriteResponseParam {
        let responseCode: UInt8
        let messageId: UInt8
        let characteristic: CBMutableCharacteristic
        let peripheralManager: CBPeripheralManager
    }

    func writeResponse(data: Data, status: ResponseStatus, _ params: WriteResponseParam) {
        guard let centrals = params.characteristic.subscribedCentrals, !centrals.isEmpty else {
            logger.error("Cannot write value to device -> No subscribed centrals...")
            return
        }

        let messages = encodePacket(data, status: status, params.responseCode, params.messageId)
        for message in messages {
            logger.info("Writing: \(message.hexString()) to: \(params.characteristic.uuid.uuidString)")
            params.peripheralManager.updateValue(message, for: params.characteristic, onSubscribedCentrals: centrals)
            Thread.sleep(forTimeInterval: .milliseconds(100))
        }
    }

    private func encodePacket(_ data: Data, status: ResponseStatus, _ responseCode: UInt8, _ messageId: UInt8) -> [Data] {
        if status == .stateUpdate {
            return [data]
        }

        var header = Data([
            UInt8(data.count + 7),
            responseCode,
            messageId,
            0, // pkgIndex
        ])
        header.append(status.rawValue.toData())

        let tmp = header + data
        let totalCommand = tmp + Crc8.calculate(tmp)

        if (totalCommand.count - header.count) <= 15 {
            let output = totalCommand + Data([0])
            return [output]
        }

        // We need to split up the command in multiple packages
        var packages: [Data] = []

        var pkgIndex: UInt8 = 1
        var remainingCommand = totalCommand.subdata(in: 4 ..< totalCommand.count)

        while remainingCommand.count > 15 {
            header[3] = pkgIndex

            let tmp2 = header + remainingCommand.subdata(in: 0 ..< 15)
            packages.append(tmp2 + Crc8.calculate(tmp2))

            remainingCommand = remainingCommand.subdata(in: 15 ..< remainingCommand.count)
            pkgIndex = UInt8(pkgIndex + 1)
        }

        header[3] = pkgIndex
        let tmp3 = header + remainingCommand

        packages.append(tmp3 + Crc8.calculate(tmp3))
        return packages
    }
}
