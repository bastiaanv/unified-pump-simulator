import CoreBluetooth
import Foundation

/// The Tandem Mobi GATT server (peripheral). Publishes the pump service with all
/// six characteristics plus the Device Information Service, defragments inbound
/// Tron packets, routes complete messages to the pump manager, and sends the
/// pump's responses back over the same characteristic.
class TandemBluetoothManager {
    var pumpManagerDelegate: TandemPumpManager?
    let logger = PumpManagerLogger(subsystem: "com.bastiaanv.tandemkit", category: "TandemBluetoothManager")
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

    private let defragmenter = TandemDefragmenter()

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

        currentStatusChar = pumpChar(TandemCharacteristic.currentStatus)
        qualifyingEventsChar = pumpChar(TandemCharacteristic.qualifyingEvents)
        historyLogChar = pumpChar(TandemCharacteristic.historyLog)
        authorizationChar = pumpChar(TandemCharacteristic.authorization)
        controlChar = pumpChar(TandemCharacteristic.control)
        controlStreamChar = pumpChar(TandemCharacteristic.controlStream)
    }

    func startAdvertising() {
        pumpBluetoothManager.bluetoothManagerDelegate = self

        let pumpService = CBMutableService(type: TandemCharacteristic.pumpService, primary: true)
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
            type: TandemCharacteristic.disManufacturerName,
            properties: [.read],
            value: Data("Tandem Diabetes Care".utf8),
            permissions: [.readable]
        )
        let model = CBMutableCharacteristic(
            type: TandemCharacteristic.disModelNumber,
            properties: [.read],
            value: Data("Mobi".utf8),
            permissions: [.readable]
        )
        let disService = CBMutableService(type: TandemCharacteristic.disService, primary: true)
        disService.characteristics = [manufacturer, model]

        let advertisingData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: "Mobi",
            CBAdvertisementDataServiceUUIDsKey: [TandemCharacteristic.pumpService],
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
    func send(response: TandemResponse, txId: UInt8) {
        guard let pumpManager = pumpManagerDelegate else { return }

        let authKey = pumpManager.currentAuthKey
        let tsr = pumpManager.currentTimeSinceReset
        let packets = TandemPacketizer.packetize(
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
        case TandemCharacteristic.currentStatus: return currentStatusChar
        case TandemCharacteristic.qualifyingEvents: return qualifyingEventsChar
        case TandemCharacteristic.historyLog: return historyLogChar
        case TandemCharacteristic.authorization: return authorizationChar
        case TandemCharacteristic.control: return controlChar
        case TandemCharacteristic.controlStream: return controlStreamChar
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

extension TandemBluetoothManager: BluetoothManagerDelegate {
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
        if characteristic.uuid == TandemCharacteristic.qualifyingEvents, data.count < 5 {
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
