import CoreBluetooth
import Foundation
import SwiftUI

public class TandemMobiPumpManager: PumpManagerProtocol {
    public static let identifier: String = "tandemmobikit"
    public var title: String = "TandemMobiKit"

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

    private let logger = PumpManagerLogger(subsystem: "com.bastiaanv.tandemmobikit", category: "TandemMobiPumpManager")
    let bluetooth: TandemMobiBluetoothManager
    var state: TandemMobiState
    var isRunning: Bool = false
    private var pairingCode: String

    /// The JPAKE responder (recreated on reset / pairing changes).
    private var jpake: TandemMobiJpake

    public required init(rawValue: StateRawValue, bluetoothManager: PumpBluetoothmanager) {
        state = TandemMobiState(rawValue: rawValue)
        pairingCode = TandemMobiPumpManager.defaultPincode
        jpake = TandemMobiJpake(
            pairingCode: pairingCode,
            existingDerivedSecret: state.derivedSecret
        )
        bluetooth = TandemMobiBluetoothManager(pumpBluetoothManager: bluetoothManager)
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
        state = TandemMobiState(rawValue: [:])
        pairingCode = TandemMobiPumpManager.defaultPincode
        jpake = TandemMobiJpake(pairingCode: pairingCode)
        notifyStateDidUpdate()
    }

    public func stop() {
        guard isRunning else { return }
        bluetooth.stopAdvertising()
        isRunning = false
        logger.info("Tandem Mobi simulator has been stopped!")
    }

    func notifyStateDidUpdate() {
        storageDelegate?.saveState(TandemMobiPumpManager.self, self)
    }

    // MARK: - Signing

    var currentAuthKey: Data? {
        guard let secret = state.derivedSecret, !secret.isEmpty,
              let nonce = state.serverNonce3, !nonce.isEmpty
        else {
            return nil
        }
        return TandemMobiHkdf.build(nonce: nonce, keyMaterial: secret)
    }

    var currentTimeSinceReset: UInt32 {
        state.timeSinceReset
    }

    private func send(_ response: TandemMobiResponse, txId: UInt8) {
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

        var response: TandemMobiResponse?

        switch characteristic {
        case TandemMobiCharacteristic.authorization:
            response = handleAuthorization(opCode: opCode, cargo: cargo)

        case TandemMobiCharacteristic.currentStatus:
            response = handleCurrentStatus(opCode: opCode)

        case TandemMobiCharacteristic.control:
            response = handleControl(opCode: opCode, cargo: cargo)

        case TandemMobiCharacteristic.historyLog:
            // History log streaming not implemented: report no history.
            if opCode == 58 {
                response = TandemMobiStatusResponses.historyLogStatus()
            }

        default:
            logger.warning("Unhandled characteristic: \(characteristic.uuidString)")
        }

        if let response = response {
            send(response, txId: txId)
        }
        notifyStateDidUpdate()
    }

    private func handleAuthorization(opCode: UInt8, cargo: Data) -> TandemMobiResponse? {
        switch opCode {
        case 16: // CentralChallengeRequest
            logger.info("Legacy central challenge pairing")
            return TandemMobiAuthResponses.centralChallenge(requestCargo: cargo)

        case 18: // PumpChallengeRequest
            return TandemMobiAuthResponses.pumpChallenge(requestCargo: cargo)

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
            return TandemMobiResponse(
                opCode: respOpCode,
                characteristic: TandemMobiCharacteristic.authorization,
                signed: false,
                cargo: respCargo
            )

        default:
            logger.warning("Unknown authorization opCode: \(opCode)")
            return nil
        }
    }

    private func handleCurrentStatus(opCode: UInt8) -> TandemMobiResponse? {
        switch opCode {
        case 54: // TimeSinceResetRequest
            return TandemMobiStatusResponses.timeSinceReset(
                currentTime: TandemMobiDates.currentTimeSinceJan12008(),
                timeSinceReset: state.timeSinceReset
            )

        case 32: // ApiVersionRequest
            return TandemMobiStatusResponses.apiVersion()

        case 132: // PumpVersionBRequest
            return TandemMobiStatusResponses.pumpVersionB(serialNumber: state.serialNumber)

        case 144: // CurrentBatteryV2Request
            return TandemMobiStatusResponses.currentBatteryV2(percent: state.batteryPercent)

        case 40: // CurrentBasalStatusRequest
            return TandemMobiStatusResponses.currentBasalStatus(
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
                return TandemMobiStatusResponses.tempRate(
                    active: 1,
                    percentage: percent,
                    startTime: UInt32(TandemMobiDates.fromDateToJan12008EpochSeconds(start)),
                    duration: UInt32(duration)
                )
            }
            return TandemMobiStatusResponses.tempRate()

        case 44: // CurrentBolusStatusRequest
            return TandemMobiStatusResponses.currentBolusStatus()

        case 138: // BasalLimitSettingsRequest
            return TandemMobiStatusResponses.basalLimitSettings(
                limitMilliunits: state.maxBasalMilliunits,
                defaultMilliunits: state.maxBasalMilliunits
            )

        case 140: // GlobalMaxBolusSettingsRequest
            return TandemMobiStatusResponses.globalMaxBolusSettings(
                maxMilliunits: state.maxBolusMilliunits,
                defaultMilliunits: state.maxBolusMilliunits
            )

        case 86: // PumpGlobalsRequest
            return TandemMobiStatusResponses.pumpGlobals()

        case 36: // InsulinStatusRequest
            return TandemMobiStatusResponses.insulinStatus()

        case 190: // CGMStatusV2Request (Mobi)
            return TandemMobiStatusResponses.cgmStatusV2()

        case 58: // HistoryLogStatusRequest
            return TandemMobiStatusResponses.historyLogStatus()

        default:
            logger.warning("Unknown current-status opCode: \(opCode)")
            return nil
        }
    }

    private func handleControl(opCode: UInt8, cargo: Data) -> TandemMobiResponse? {
        switch opCode {
        case 136: // SetMaxBasalLimitRequest
            if cargo.count >= 4 {
                state.maxBasalMilliunits = TandemMobiBytes.readU32(cargo, 0)
            }
            return TandemMobiControlResponses.ack(137)

        case 134: // SetMaxBolusLimitRequest
            if cargo.count >= 2 {
                state.maxBolusMilliunits = TandemMobiBytes.readU16(cargo, 0)
            }
            return TandemMobiControlResponses.ack(135)

        case 162: // BolusPermissionRequest
            let bolusId = state.nextBolusId
            return TandemMobiControlResponses.bolusPermission(status: 0, bolusId: bolusId, nackReasonId: 0)

        case 158: // InitiateBolusRequest
            let totalVolume = cargo.count >= 4 ? TandemMobiBytes.readU32(cargo, 0) : 0
            let bolusId = cargo.count >= 6 ? TandemMobiBytes.readU16(cargo, 4) : 0
            let units = Double(totalVolume) / 1000.0
            state.reservoirLevel = max(0, state.reservoirLevel - units)
            state.bolusTotal = units
            state.bolusProgress = units
            return TandemMobiControlResponses.initiateBolus(status: 0, bolusId: bolusId, statusTypeId: 0)

        case 250: // AdditionalBolusRequest
            let bolusId = cargo.count >= 4 ? TandemMobiBytes.readU16(cargo, 0) : 0
            return TandemMobiControlResponses.additionalBolus(status: 0, bolusId: bolusId, reserve: 0)

        case 160: // CancelBolusRequest
            let bolusId = cargo.count >= 4 ? TandemMobiBytes.readU16(cargo, 0) : 0
            state.bolusProgress = nil
            state.bolusTotal = nil
            return TandemMobiControlResponses.cancelBolus(statusId: 0, bolusId: bolusId, reasonId: 0)

        case 240: // BolusPermissionReleaseRequest
            return TandemMobiControlResponses.ack(241)

        case 164: // SetTempRateRequest
            if cargo.count >= 6 {
                let durationMs = TandemMobiBytes.readU32(cargo, 0)
                let percent = TandemMobiBytes.readU16(cargo, 4)
                let rate = state.currentBaseBasalRate * Double(percent) / 100.0
                state.tempBasalRate = rate
                state.tempBasalStart = Date.now
                state.tempBasalDuration = TimeInterval(durationMs / 1000)
            }
            return TandemMobiControlResponses.setTempRate(status: 0, tempRateId: 0)

        case 166: // StopTempRateRequest
            state.tempBasalRate = nil
            state.tempBasalStart = nil
            state.tempBasalDuration = nil
            return TandemMobiControlResponses.stopTempRate(status: 0, tempRateId: 0)

        case 156: // SuspendPumpingRequest
            if state.suspendedSince == nil {
                state.suspendedSince = Date.now
            }
            return TandemMobiControlResponses.ack(157)

        case 154: // ResumePumpingRequest
            state.suspendedSince = nil
            state.suspendedDuration = nil
            return TandemMobiControlResponses.ack(155)

        case 214: // ChangeTimeDateRequest
            if cargo.count >= 4 {
                let epoch = TandemMobiBytes.readU32(cargo, 0)
                let date = Date(timeIntervalSince1970: TandemMobiDates.toUnixEpochSeconds(TimeInterval(epoch)))
                state.timeSinceReset = 0
                logger.info("Pump time set to \(date)")
            }
            return TandemMobiControlResponses.ack(215)

        case 210: // SetQuickBolusSettingsRequest
            return TandemMobiControlResponses.ack(211)

        case 184: // DismissNotificationRequest
            return TandemMobiControlResponses.ack(185)

        case 204: // SetModesRequest
            return TandemMobiControlResponses.ack(205)

        case 206: // SetSleepScheduleRequest
            return TandemMobiControlResponses.ack(207)

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
