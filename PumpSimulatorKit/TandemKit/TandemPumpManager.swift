import CoreBluetooth
import Foundation
import SwiftUI

public class TandemPumpManager: PumpManagerProtocol {
    public static let identifier: String = "tandemkit"
    public var title: String = "TandemKit"

    public var capabilities = PumpManagerCapabitilties(
        supportedModels: [
            PumpModel(name: "Mobi", image: Image(imageName: "mobi"), index: 0),
        ],
        canExpire: false,
        actions: []
    )

    /// Pairing PIN the pump advertises as accepted. A real Loop/Trio central must
    /// enter this to pair. Persisted so reconnect works with the same code.
    public static let defaultPincode = "000000"

    public var currentModel: PumpModel {
        get { capabilities.supportedModels[0] }
        set {}
    }

    public var pumpState: String {
        if state.hasPairingArtifacts() {
            return "Paired"
        }
        return "Not paired"
    }

    public var pumpNotes: String {
        "Tandem Mobi - serial \(String(format: "%08X", state.serialNumber)) (PIN \(pairingCode))"
    }

    public var expiresAt: Date? {
        nil
    }

    public var activatedAt: Date? {
        state.activatedAt
    }

    public var basal: [BasalItem] {
        get { state.basal }
        set {
            state.basal = newValue
            notifyStateDidUpdate()
        }
    }

    public var batteryLevel: String? {
        "\(state.batteryPercent)%"
    }

    public var reservoirLevel: Double {
        state.reservoirLevel
    }

    public var basalState: BasalState {
        if let rate = state.tempBasalRate,
           let start = state.tempBasalStart,
           let duration = state.tempBasalDuration
        {
            if start.addingTimeInterval(duration) < Date.now {
                state.tempBasalRate = nil
                state.tempBasalStart = nil
                state.tempBasalDuration = nil
                notifyStateDidUpdate()
                return .active(rate: state.currentBaseBasalRate)
            }
            return .tempBasal(rate: rate, start: start, end: start + duration)
        }

        if let suspendedSince = state.suspendedSince {
            return .suspended(start: suspendedSince, duration: state.suspendedDuration)
        }

        return .active(rate: state.currentBaseBasalRate)
    }

    public var bolusProgress: BolusState? {
        guard let progress = state.bolusProgress, let total = state.bolusTotal else {
            return nil
        }
        return BolusState(total: total, progress: progress)
    }

    public var storageDelegate: (any StorageDelegate)?
    public var rawState: StateRawValue {
        state.getRaw()
    }

    private let logger = PumpManagerLogger(subsystem: "com.bastiaanv.tandemkit", category: "TandemPumpManager")
    let bluetooth: TandemBluetoothManager
    var state: TandemState
    var isRunning: Bool = false
    private var pairingCode: String

    /// The JPAKE responder (recreated on reset / pairing changes).
    private var jpake: TandemJpake

    public required init(rawValue: StateRawValue, bluetoothManager: PumpBluetoothmanager) {
        state = TandemState(rawValue: rawValue)
        pairingCode = TandemPumpManager.defaultPincode
        jpake = TandemJpake(
            pairingCode: pairingCode,
            existingDerivedSecret: state.derivedSecret
        )
        bluetooth = TandemBluetoothManager(pumpBluetoothManager: bluetoothManager)
        bluetooth.pumpManagerDelegate = self
    }

    public func startAdvertising() {
        if state.activatedAt == nil {
            state.activatedAt = Date.now
            notifyStateDidUpdate()
        }
        bluetooth.startAdvertising()
        isRunning = true
    }

    public func reset() {
        state = TandemState(rawValue: [:])
        pairingCode = TandemPumpManager.defaultPincode
        jpake = TandemJpake(pairingCode: pairingCode)
        notifyStateDidUpdate()
    }

    public func stop() {
        guard isRunning else { return }
        bluetooth.stopAdvertising()
        isRunning = false
        logger.info("Tandem Mobi simulator has been stopped!")
    }

    func notifyStateDidUpdate() {
        storageDelegate?.saveState(TandemPumpManager.self, self)
    }

    // MARK: - Signing

    var currentAuthKey: Data? {
        guard let secret = state.derivedSecret, !secret.isEmpty,
              let nonce = state.serverNonce3, !nonce.isEmpty
        else {
            return nil
        }
        return TandemHkdf.build(nonce: nonce, keyMaterial: secret)
    }

    var currentTimeSinceReset: UInt32 {
        state.timeSinceReset
    }

    private func send(_ response: TandemResponse, txId: UInt8) {
        bluetooth.send(response: response, txId: txId)
    }

    // MARK: - Inbound dispatch

    func handleMessage(
        opCode: UInt8,
        characteristic: CBUUID,
        cargo: Data,
        txId: UInt8,
        peripheralManager _: CBPeripheralManager
    ) {
        logger.info("Handle opCode \(opCode) on \(characteristic.uuidString), cargo: \(cargo.hexString())")

        var response: TandemResponse?

        switch characteristic {
        case TandemCharacteristic.authorization:
            response = handleAuthorization(opCode: opCode, cargo: cargo)

        case TandemCharacteristic.currentStatus:
            response = handleCurrentStatus(opCode: opCode)

        case TandemCharacteristic.control:
            response = handleControl(opCode: opCode, cargo: cargo)

        case TandemCharacteristic.historyLog:
            // History log streaming not implemented: report no history.
            if opCode == 58 {
                response = TandemStatusResponses.historyLogStatus()
            }

        default:
            logger.warning("Unhandled characteristic: \(characteristic.uuidString)")
        }

        if let response = response {
            send(response, txId: txId)
        }
        notifyStateDidUpdate()
    }

    private func handleAuthorization(opCode: UInt8, cargo: Data) -> TandemResponse? {
        switch opCode {
        case 16: // CentralChallengeRequest
            logger.info("Legacy central challenge pairing")
            return TandemAuthResponses.centralChallenge(requestCargo: cargo)

        case 18: // PumpChallengeRequest
            return TandemAuthResponses.pumpChallenge(requestCargo: cargo)

        case 32,
             34,
             36,
             38,
             40: // JPAKE rounds
            guard let (respOpCode, respCargo) = jpake.handleRequest(opCode: opCode, cargo: cargo) else {
                logger.error("JPAKE could not handle op \(opCode)")
                return nil
            }
            // Persist pairing artifacts once the handshake completes.
            if jpake.isComplete {
                state.derivedSecret = jpake.derivedSecret
                state.serverNonce3 = jpake.serverNonce3
                logger.info("JPAKE handshake complete for Tandem Mobi")
            }
            return TandemResponse(
                opCode: respOpCode,
                characteristic: TandemCharacteristic.authorization,
                signed: false,
                cargo: respCargo
            )

        default:
            logger.warning("Unknown authorization opCode: \(opCode)")
            return nil
        }
    }

    private func handleCurrentStatus(opCode: UInt8) -> TandemResponse? {
        switch opCode {
        case 54: // TimeSinceResetRequest
            return TandemStatusResponses.timeSinceReset(
                currentTime: TandemDates.currentTimeSinceJan12008(),
                timeSinceReset: state.timeSinceReset
            )

        case 32: // ApiVersionRequest
            return TandemStatusResponses.apiVersion()

        case 132: // PumpVersionBRequest
            return TandemStatusResponses.pumpVersionB(serialNumber: state.serialNumber)

        case 144: // CurrentBatteryV2Request
            return TandemStatusResponses.currentBatteryV2(percent: state.batteryPercent)

        case 40: // CurrentBasalStatusRequest
            return TandemStatusResponses.currentBasalStatus(
                profileRateMilliunits: milliunits(state.currentBaseBasalRate),
                currentRateMilliunits: milliunits(currentBasalRate),
                modifiedBitmask: basalModifiedBitmask
            )

        case 42: // TempRateRequest
            if let rate = state.tempBasalRate,
               let start = state.tempBasalStart,
               let duration = state.tempBasalDuration
            {
                let percent = UInt8(min(100, Int(rate / state.currentBaseBasalRate * 100)))
                return TandemStatusResponses.tempRate(
                    active: 1,
                    percentage: percent,
                    startTime: UInt32(TandemDates.fromDateToJan12008EpochSeconds(start)),
                    duration: UInt32(duration)
                )
            }
            return TandemStatusResponses.tempRate()

        case 44: // CurrentBolusStatusRequest
            return TandemStatusResponses.currentBolusStatus()

        case 138: // BasalLimitSettingsRequest
            return TandemStatusResponses.basalLimitSettings(
                limitMilliunits: state.maxBasalMilliunits,
                defaultMilliunits: state.maxBasalMilliunits
            )

        case 140: // GlobalMaxBolusSettingsRequest
            return TandemStatusResponses.globalMaxBolusSettings(
                maxMilliunits: state.maxBolusMilliunits,
                defaultMilliunits: state.maxBolusMilliunits
            )

        case 86: // PumpGlobalsRequest
            return TandemStatusResponses.pumpGlobals()

        case 36: // InsulinStatusRequest
            return TandemStatusResponses.insulinStatus()

        case 190: // CGMStatusV2Request (Mobi)
            return TandemStatusResponses.cgmStatusV2()

        case 58: // HistoryLogStatusRequest
            return TandemStatusResponses.historyLogStatus()

        default:
            logger.warning("Unknown current-status opCode: \(opCode)")
            return nil
        }
    }

    private func handleControl(opCode: UInt8, cargo: Data) -> TandemResponse? {
        switch opCode {
        case 136: // SetMaxBasalLimitRequest
            if cargo.count >= 4 {
                state.maxBasalMilliunits = TandemBytes.readU32(cargo, 0)
            }
            return TandemControlResponses.ack(137)

        case 134: // SetMaxBolusLimitRequest
            if cargo.count >= 2 {
                state.maxBolusMilliunits = TandemBytes.readU16(cargo, 0)
            }
            return TandemControlResponses.ack(135)

        case 162: // BolusPermissionRequest
            let bolusId = state.nextBolusId
            return TandemControlResponses.bolusPermission(status: 0, bolusId: bolusId, nackReasonId: 0)

        case 158: // InitiateBolusRequest
            let totalVolume = cargo.count >= 4 ? TandemBytes.readU32(cargo, 0) : 0
            let bolusId = cargo.count >= 6 ? TandemBytes.readU16(cargo, 4) : 0
            let units = Double(totalVolume) / 1000.0
            state.reservoirLevel = max(0, state.reservoirLevel - units)
            state.bolusTotal = units
            state.bolusProgress = units
            return TandemControlResponses.initiateBolus(status: 0, bolusId: bolusId, statusTypeId: 0)

        case 250: // AdditionalBolusRequest
            let bolusId = cargo.count >= 4 ? TandemBytes.readU16(cargo, 0) : 0
            return TandemControlResponses.additionalBolus(status: 0, bolusId: bolusId, reserve: 0)

        case 160: // CancelBolusRequest
            let bolusId = cargo.count >= 4 ? TandemBytes.readU16(cargo, 0) : 0
            state.bolusProgress = nil
            state.bolusTotal = nil
            return TandemControlResponses.cancelBolus(statusId: 0, bolusId: bolusId, reasonId: 0)

        case 240: // BolusPermissionReleaseRequest
            return TandemControlResponses.ack(241)

        case 164: // SetTempRateRequest
            if cargo.count >= 6 {
                let durationMs = TandemBytes.readU32(cargo, 0)
                let percent = TandemBytes.readU16(cargo, 4)
                let rate = state.currentBaseBasalRate * Double(percent) / 100.0
                state.tempBasalRate = rate
                state.tempBasalStart = Date.now
                state.tempBasalDuration = TimeInterval(durationMs / 1000)
            }
            return TandemControlResponses.setTempRate(status: 0, tempRateId: 0)

        case 166: // StopTempRateRequest
            state.tempBasalRate = nil
            state.tempBasalStart = nil
            state.tempBasalDuration = nil
            return TandemControlResponses.stopTempRate(status: 0, tempRateId: 0)

        case 156: // SuspendPumpingRequest
            if state.suspendedSince == nil {
                state.suspendedSince = Date.now
            }
            return TandemControlResponses.ack(157)

        case 154: // ResumePumpingRequest
            state.suspendedSince = nil
            state.suspendedDuration = nil
            return TandemControlResponses.ack(155)

        case 214: // ChangeTimeDateRequest
            if cargo.count >= 4 {
                let epoch = TandemBytes.readU32(cargo, 0)
                let date = Date(timeIntervalSince1970: TandemDates.toUnixEpochSeconds(TimeInterval(epoch)))
                state.timeSinceReset = 0
                logger.info("Pump time set to \(date)")
            }
            return TandemControlResponses.ack(215)

        case 210: // SetQuickBolusSettingsRequest
            return TandemControlResponses.ack(211)

        case 184: // DismissNotificationRequest
            return TandemControlResponses.ack(185)

        case 204: // SetModesRequest
            return TandemControlResponses.ack(205)

        case 206: // SetSleepScheduleRequest
            return TandemControlResponses.ack(207)

        default:
            logger.warning("Unknown control opCode: \(opCode)")
            return nil
        }
    }

    // MARK: - Helpers

    private var currentBasalRate: Double {
        if state.suspendedSince != nil {
            return 0
        }
        if let rate = state.tempBasalRate {
            return rate
        }
        return state.currentBaseBasalRate
    }

    private var basalModifiedBitmask: UInt8 {
        if state.suspendedSince != nil {
            return 0x01
        }
        if state.tempBasalRate != nil {
            return 0x02
        }
        return 0x00
    }

    private func milliunits(_ unitsPerHour: Double) -> UInt32 {
        UInt32(max(0, unitsPerHour * 1000))
    }
}
