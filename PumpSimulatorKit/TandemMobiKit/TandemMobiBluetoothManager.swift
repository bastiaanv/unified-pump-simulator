import CoreBluetooth
import Foundation

/// The Tandem Mobi GATT server (peripheral). Publishes the pump service with all
/// six characteristics plus the Device Information Service, defragments inbound
/// Tron packets, routes complete messages to the pump manager, and sends the
/// pump's responses back over the same characteristic.
class TandemMobiBluetoothManager {
    var pumpManagerDelegate: TandemMobiPumpManager?
    let logger = PumpManagerLogger(subsystem: "com.bastiaanv.tandemmobikit", category: "TandemMobiBluetoothManager")
    private let pumpBluetoothManager: PumpBluetoothmanager

    // Pump service characteristics.
    let currentStatusChar: CBMutableCharacteristic
    let qualifyingEventsChar: CBMutableCharacteristic
    let historyLogChar: CBMutableCharacteristic
    let authorizationChar: CBMutableCharacteristic
    let controlChar: CBMutableCharacteristic
    let controlStreamChar: CBMutableCharacteristic

    var subscribedCentrals: [CBCentral] = []
    var writeQueue: [(Data, CBMutableCharacteristic)] = []

    private let defragmenter = TandemMobiDefragmenter()

    init(pumpBluetoothManager: PumpBluetoothmanager) {
        self.pumpBluetoothManager = pumpBluetoothManager

        func pumpChar(_ uuid: CBUUID) -> CBMutableCharacteristic {
            CBMutableCharacteristic(
                type: uuid,
                properties: [.write, .notify, .indicate],
                value: nil,
                permissions: .writeable
            )
        }

        currentStatusChar = pumpChar(TandemMobiCharacteristic.currentStatus)
        qualifyingEventsChar = pumpChar(TandemMobiCharacteristic.qualifyingEvents)
        historyLogChar = pumpChar(TandemMobiCharacteristic.historyLog)
        authorizationChar = pumpChar(TandemMobiCharacteristic.authorization)
        controlChar = pumpChar(TandemMobiCharacteristic.control)
        controlStreamChar = pumpChar(TandemMobiCharacteristic.controlStream)
    }

    func startAdvertising() {
        pumpBluetoothManager.bluetoothManagerDelegate = self

        let pumpService = CBMutableService(type: TandemMobiCharacteristic.pumpService, primary: true)
        pumpService.characteristics = [
            currentStatusChar,
            qualifyingEventsChar,
            historyLogChar,
            authorizationChar,
            controlChar,
            controlStreamChar,
        ]

        // Device Information Service (must be readable and non-empty).
        let manufacturer = CBMutableCharacteristic(
            type: TandemMobiCharacteristic.disManufacturerName,
            properties: [.read],
            value: Data("Tandem Diabetes Care".utf8),
            permissions: [.readable]
        )
        let model = CBMutableCharacteristic(
            type: TandemMobiCharacteristic.disModelNumber,
            properties: [.read],
            value: Data("Mobi".utf8),
            permissions: [.readable]
        )
        let disService = CBMutableService(type: TandemMobiCharacteristic.disService, primary: true)
        disService.characteristics = [manufacturer, model]

        let advertisingData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: "Mobi",
            CBAdvertisementDataServiceUUIDsKey: [TandemMobiCharacteristic.pumpService],
        ]

        pumpBluetoothManager.startAdvertising(
            services: [pumpService, disService],
            advertisingData: advertisingData
        )
    }

    func stopAdvertising() {
        pumpBluetoothManager.stopAdvertising()
        subscribedCentrals.removeAll()
        writeQueue.removeAll()
        defragmenter.reset()
    }

    /// Enqueue a response (as its sequence of ATT packets) to be streamed back to
    /// the central on the same characteristic it arrived on.
    func send(response: TandemMobiResponse, txId: UInt8) {
        guard let pumpManager = pumpManagerDelegate else { return }

        let authKey = pumpManager.currentAuthKey
        let tsr = pumpManager.currentTimeSinceReset
        let packets = TandemMobiPacketizer.packetize(
            response: response,
            authKey: authKey,
            txId: txId,
            timeSinceReset: tsr
        )

        guard let characteristic = characteristic(for: response.characteristic) else {
            logger.error("No characteristic for UUID \(response.characteristic)")
            return
        }

        for packet in packets {
            writeQueue.append((packet.build(), characteristic))
        }
    }

    private func characteristic(for uuid: CBUUID) -> CBMutableCharacteristic? {
        switch uuid {
        case TandemMobiCharacteristic.currentStatus: return currentStatusChar
        case TandemMobiCharacteristic.qualifyingEvents: return qualifyingEventsChar
        case TandemMobiCharacteristic.historyLog: return historyLogChar
        case TandemMobiCharacteristic.authorization: return authorizationChar
        case TandemMobiCharacteristic.control: return controlChar
        case TandemMobiCharacteristic.controlStream: return controlStreamChar
        default: return nil
        }
    }

    private func flushWriteQueue(_ peripheral: CBPeripheralManager) {
        guard let item = writeQueue.first else { return }
        guard let centrals = item.1.subscribedCentrals, !centrals.isEmpty else {
            logger.error("Cannot write value to device -> No subscribed centrals...")
            return
        }

        logger.info("Writing: \(item.0.hexString()), to: \(item.1.uuid.uuidString)")
        guard peripheral.updateValue(item.0, for: item.1, onSubscribedCentrals: centrals) else {
            return
        }

        writeQueue.removeFirst()
        flushWriteQueue(peripheral)
    }
}

// MARK: - BluetoothManagerDelegate

extension TandemMobiBluetoothManager: BluetoothManagerDelegate {
    func didStartAdvertising(_ error: (any Error)?) {
        if let error = error {
            logger.error("Failed to start advertising: \(error.localizedDescription)")
            return
        }
        logger.info("Tandem Mobi simulator has started!")
    }

    func didReceiveWrite(
        _ peripheralManager: CBPeripheralManager,
        characteristic: CBCharacteristic,
        data: Data,
        request: CBATTRequest
    ) {
        defer { peripheralManager.respond(to: request, withResult: .success) }

        // QUALIFYING_EVENTS ack is a raw 4-byte write, not a Tron packet.
        if characteristic.uuid == TandemMobiCharacteristic.qualifyingEvents, data.count < 5 {
            logger.info("Received qualifying-events ack: \(data.hexString())")
            return
        }

        logger.info("Received write on \(characteristic.uuid.uuidString): \(data.hexString())")

        guard let pumpManager = pumpManagerDelegate else {
            logger.error("No pumpManagerDelegate")
            return
        }

        guard let message = defragmenter.ingest(data, characteristic: characteristic.uuid) else {
            logger.info("Message not complete...")
            return
        }

        pumpManager.handleMessage(
            opCode: message.opCode,
            characteristic: characteristic.uuid,
            cargo: message.cargo,
            txId: message.txId,
            peripheralManager: peripheralManager
        )

        flushWriteQueue(peripheralManager)
    }

    func didReceiveSubscribe(central: CBCentral, peripheralManager _: CBPeripheralManager) {
        if subscribedCentrals.contains(central) {
            return
        }
        subscribedCentrals.append(central)
        logger.info("Central subscribed to Tandem Mobi")
    }

    func didUnsubscribe(central: CBCentral) {
        if let index = subscribedCentrals.firstIndex(of: central) {
            subscribedCentrals.remove(at: index)
        }
    }

    func readyForNextMessage(_ peripheral: CBPeripheralManager) {
        flushWriteQueue(peripheral)
    }
}
