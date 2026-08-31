import CoreBluetooth
import Foundation

/// The MiniMed Flex pump GATT server. Registers the services/characteristics from
/// `GATT/GATTProfile.swift`, receives the phone's writes, and dispatches each CCMP
/// message to the secure-link handler or the therapy/status packet handlers.
class FlexKitBluetoothManager {
    var pumpManagerDelegate: FlexKitPumpManager?
    let logger = PumpManagerLogger(subsystem: "com.bastiaanv.flexkit", category: "FlexKitBluetoothManager")
    private let pumpBluetoothManager: PumpBluetoothmanager

    // Secure-link machinery (Tier A: transparent link).
    let handshake = SecureLinkHandshake()
    let sequencer = TLSMessageSequencer()

    // Service / characteristic references.
    private let iddService: CBMutableService
    private let deviceTimeService: CBMutableService
    private let rtMtsService: CBMutableService
    private let nrtMtsService: CBMutableService
    private let connMgmService: CBMutableService

    private let control7101: CBMutableCharacteristic
    let data7102: CBMutableCharacteristic
    let notification7103: CBMutableCharacteristic
    private let configuration7104: CBMutableCharacteristic
    private let iddChars: [CBMutableCharacteristic]
    private let racpChar: CBMutableCharacteristic
    private let deviceTimeChars: [CBMutableCharacteristic]

    var subscribedCentrals: [CBCentral] = []
    var writeQueue: [(Data, CBMutableCharacteristic)] = []

    init(pumpBluetoothManager: PumpBluetoothmanager) {
        self.pumpBluetoothManager = pumpBluetoothManager

        control7101 = CBMutableCharacteristic(
            type: MiniMedGATT.RealTimeMTS.controlPoint,
            properties: [.write, .writeWithoutResponse, .notify, .indicate],
            value: nil,
            permissions: .writeable
        )
        data7102 = CBMutableCharacteristic(
            type: MiniMedGATT.RealTimeMTS.data,
            properties: [.write, .writeWithoutResponse, .notify, .indicate],
            value: nil,
            permissions: .writeable
        )
        notification7103 = CBMutableCharacteristic(
            type: MiniMedGATT.RealTimeMTS.notification,
            properties: [.notify, .indicate],
            value: nil,
            permissions: .readable
        )
        configuration7104 = CBMutableCharacteristic(
            type: MiniMedGATT.RealTimeMTS.configuration,
            properties: [.read],
            value: MTS.encodeConfiguration(),
            permissions: .readable
        )

        /// IDD characteristics.
        func iddChar(_ uuid: CBUUID) -> CBMutableCharacteristic {
            CBMutableCharacteristic(
                type: uuid,
                properties: [.write, .writeWithoutResponse, .notify, .indicate],
                value: nil,
                permissions: .writeable
            )
        }
        iddChars = [
            iddChar(MiniMedGATT.iddChar0101),
            iddChar(MiniMedGATT.iddChar0102),
            iddChar(MiniMedGATT.iddChar0103),
            iddChar(MiniMedGATT.iddChar0108),
            iddChar(MiniMedGATT.iddChar0110),
            iddChar(MiniMedGATT.iddChar0112),
            iddChar(MiniMedGATT.iddChar0113),
            iddChar(MiniMedGATT.iddChar0114),
        ]

        racpChar = CBMutableCharacteristic(
            type: MiniMedGATT.racp,
            properties: [.write, .writeWithoutResponse, .notify, .indicate],
            value: nil,
            permissions: .writeable
        )

        deviceTimeChars = [
            CBMutableCharacteristic(
                type: MiniMedGATT.deviceTimeChar1,
                properties: [.write, .writeWithoutResponse, .notify, .indicate],
                value: nil,
                permissions: .writeable
            ),
            CBMutableCharacteristic(
                type: MiniMedGATT.deviceTimeChar2,
                properties: [.write, .writeWithoutResponse, .notify, .indicate],
                value: nil,
                permissions: .writeable
            ),
        ]

        iddService = CBMutableService(type: MiniMedGATT.iddService, primary: true)
        iddService.characteristics = iddChars + [racpChar]

        deviceTimeService = CBMutableService(type: MiniMedGATT.deviceTimeService, primary: true)
        deviceTimeService.characteristics = deviceTimeChars

        rtMtsService = CBMutableService(type: MiniMedGATT.realTimeMTS, primary: true)
        rtMtsService.characteristics = [control7101, data7102, notification7103, configuration7104]

        nrtMtsService = CBMutableService(type: MiniMedGATT.nonRealTimeMTS, primary: true)
        nrtMtsService.characteristics = [
            CBMutableCharacteristic(
                type: MiniMedGATT.NonRealTimeMTS.controlPoint,
                properties: [.write, .writeWithoutResponse, .notify, .indicate],
                value: nil,
                permissions: .writeable
            ),
        ]

        connMgmService = CBMutableService(type: MiniMedGATT.connectionMgmMTS, primary: true)
        connMgmService.characteristics = [
            CBMutableCharacteristic(
                type: MiniMedGATT.ConnectionMgmMTS.controlPoint,
                properties: [.write, .writeWithoutResponse, .notify, .indicate],
                value: nil,
                permissions: .writeable
            ),
        ]
    }

    func startAdvertising() {
        pumpBluetoothManager.bluetoothManagerDelegate = self

        let services = [iddService, deviceTimeService, rtMtsService, nrtMtsService, connMgmService]

        // Manufacturer data: company-id 0x1010 (LE) + deviceId / flags / frameType.
        var manufacturerData = Data()
        manufacturerData.append(0x10) // company id low (0x1010)
        manufacturerData.append(0x10) // company id high
        manufacturerData.append(0x00) // deviceId
        manufacturerData.append(0x01) // flags
        manufacturerData.append(0x00) // frameType

        let advertisingData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: "MiniMed",
            CBAdvertisementDataServiceUUIDsKey: [MiniMedGATT.insulinDeliveryService],
            CBAdvertisementDataManufacturerDataKey: manufacturerData,
        ]

        pumpBluetoothManager.startAdvertising(services: services, advertisingData: advertisingData)
    }

    func stopAdvertising() {
        pumpBluetoothManager.stopAdvertising()
        subscribedCentrals.removeAll()
        writeQueue.removeAll()
        handshake.reset()
        sequencer.reset()
    }
}

// MARK: - Inbound processing

extension FlexKitBluetoothManager {
    /// Parse the raw value written by the phone into a CCMP frame.
    private func parseInbound(
        characteristic: CBCharacteristic,
        data: Data
    ) -> CCMPFormat0.Frame? {
        var body = data

        // Encrypted characteristics carry a 1-byte sequence prefix.
        if MiniMedGATT.isEncrypted(characteristic.uuid), !body.isEmpty {
            body = body.subdata(in: 1 ..< body.count)
            sequencer.releaseCryptoLock()
        }

        // The body may be wrapped in an MTS transmit frame; if so unwrap it.
        if let ccmp = MTS.decodeRequest(body), !ccmp.isEmpty {
            body = ccmp
        }

        guard let frame = try? CCMPFormat0.decode(body) else {
            logger.warning("Failed to decode CCMP frame: \(body.hexString())")
            return nil
        }
        return frame
    }

    func processMessage(
        messageID: UInt16,
        payload: Data,
        characteristic _: CBCharacteristic,
        peripheralManager: CBPeripheralManager
    ) {
        guard let pumpManager = pumpManagerDelegate else { return }

        switch messageID {
        // Secure-link handshake / passkey.
        case CcmpMsgID.authError.rawValue,
             CcmpMsgID.clientFinished.rawValue,
             CcmpMsgID.clientHello.rawValue,
             CcmpMsgID.passkey.rawValue:
            let responses = (try? handshake.handle(
                messageID: messageID,
                payload: payload,
                passkey: pumpManager.state.passkey
            )) ?? []
            for (id, rspPayload) in responses {
                sendCCMP(messageID: id, payload: rspPayload, to: data7102, peripheralManager: peripheralManager)
            }

        // Pump-certificate get/set — stub (Tier A).
        case CcmpMsgID.certGetReq.rawValue:
            sendCCMP(
                messageID: CcmpMsgID.certGetReply.rawValue,
                payload: Data([0x01, 0x04, 0x00, 0x00]),
                to: data7102,
                peripheralManager: peripheralManager
            )

        case CcmpMsgID.certSetReq.rawValue:
            sendCCMP(
                messageID: CcmpMsgID.certSetReply.rawValue,
                payload: Data([0x01, 0x01]),
                to: data7102,
                peripheralManager: peripheralManager
            )

        // FOTA — stub "no update".
        case CcmpMsgID.fotaStatusReq.rawValue:
            sendCCMP(
                messageID: CcmpMsgID.fotaStatusRsp.rawValue,
                payload: Data([0x00, 0, 0, 0] + [UInt8](repeating: 0, count: 32)),
                to: data7102,
                peripheralManager: peripheralManager
            )

        // Therapy / status / device-time / history.
        default:
            handleTherapy(messageID: messageID, payload: payload, pumpManager: pumpManager, peripheralManager: peripheralManager)
        }
    }

    private func handleTherapy(
        messageID: UInt16,
        payload: Data,
        pumpManager: FlexKitPumpManager,
        peripheralManager: CBPeripheralManager
    ) {
        let params = PacketParams(
            manager: self,
            pumpManager: pumpManager,
            peripheralManager: peripheralManager,
            messageID: messageID
        )

        if FlexKitTimePackets.process(payload, params) {
            return
        }
        if FlexKitStatusPackets.process(payload, params) {
            return
        }
        if FlexKitSystemConfigPackets.process(payload, params) {
            return
        }
        FlexKitCommandPackets.process(messageID: messageID, payload: payload, params: params)
    }
}

// MARK: - Write sending

extension FlexKitBluetoothManager {
    struct WriteParams {
        let characteristic: CBMutableCharacteristic
        let peripheralManager: CBPeripheralManager
    }

    /// Context handed to the packet handlers so they can mutate `state`, notify the
    /// UI, and push responses back onto the write queue.
    struct PacketParams {
        let manager: FlexKitBluetoothManager
        let pumpManager: FlexKitPumpManager
        let peripheralManager: CBPeripheralManager
        let messageID: UInt16
    }

    /// Wrap a CCMP frame in the on-wire value and enqueue it for delivery.
    /// Encrypted characteristics are prefixed with the 1-byte sequence number.
    func sendCCMP(
        messageID: UInt16,
        payload: Data,
        to characteristic: CBMutableCharacteristic,
        peripheralManager: CBPeripheralManager
    ) {
        let frame = CCMPFormat0.encode(messageID: messageID, payload: payload)
        var wire = frame
        if MiniMedGATT.isEncrypted(characteristic.uuid) {
            wire = Data(sequencer.prefixWithSequenceNumber(Array(frame)))
        }
        writeQueue.append((wire, characteristic))
        readyForNextMessage(peripheralManager)
    }

    /// Write the notification doorbell `[1][size u32 LE]` to `7103`.
    func sendNotificationDoorbell(size: UInt32, peripheralManager: CBPeripheralManager) {
        writeQueue.append((MTS.notificationDoorbell(size: size), notification7103))
        readyForNextMessage(peripheralManager)
    }

    func readyForNextMessage(_ peripheral: CBPeripheralManager) {
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
        readyForNextMessage(peripheral)
    }
}

// MARK: - BluetoothManagerDelegate

extension FlexKitBluetoothManager: BluetoothManagerDelegate {
    func didStartAdvertising(_ error: (any Error)?) {
        if let error = error {
            logger.error("Failed to start advertising: \(error.localizedDescription)")
            return
        }
        logger.info("MiniMed Flex simulator has started!")
    }

    func didReceiveWrite(
        _ peripheralManager: CBPeripheralManager,
        characteristic: CBCharacteristic,
        data: Data,
        request: CBATTRequest
    ) {
        guard characteristic.uuid != MiniMedGATT.RealTimeMTS.configuration else {
            peripheralManager.respond(to: request, withResult: .success)
            return
        }

        logger.info("Received write on \(characteristic.uuid.uuidString): \(data.hexString())")

        guard let frame = parseInbound(characteristic: characteristic, data: data) else {
            logger.warning("Could not parse inbound message")
            peripheralManager.respond(to: request, withResult: .success)
            return
        }

        processMessage(
            messageID: frame.messageID,
            payload: frame.payload,
            characteristic: characteristic,
            peripheralManager: peripheralManager
        )

        peripheralManager.respond(to: request, withResult: .success)
    }

    func didReceiveSubscribe(central: CBCentral, peripheralManager _: CBPeripheralManager) {
        if subscribedCentrals.contains(central) {
            return
        }
        subscribedCentrals.append(central)
        logger.info("Central subscribed to MiniMed Flex")
    }

    func didUnsubscribe(central: CBCentral) {
        if let index = subscribedCentrals.firstIndex(of: central) {
            subscribedCentrals.remove(at: index)
        }
    }
}
