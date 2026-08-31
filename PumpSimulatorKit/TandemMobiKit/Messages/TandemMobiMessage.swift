import CoreBluetooth
import Foundation

/// GATT services/characteristics that a real Tandem Mobi exposes. Copied from
/// TandemKit's ServiceUUID.swift / CharacteristicUUID.swift.
enum TandemMobiCharacteristic {
    static let pumpService = CBUUID(string: "0000FDFB-0000-1000-8000-00805F9B34FB")

    static let currentStatus = CBUUID(string: "7B83FFF6-9F77-4E5C-8064-AAE2C24838B9")
    static let qualifyingEvents = CBUUID(string: "7B83FFF7-9F77-4E5C-8064-AAE2C24838B9")
    static let historyLog = CBUUID(string: "7B83FFF8-9F77-4E5C-8064-AAE2C24838B9")
    static let authorization = CBUUID(string: "7B83FFF9-9F77-4E5C-8064-AAE2C24838B9")
    static let control = CBUUID(string: "7B83FFFC-9F77-4E5C-8064-AAE2C24838B9")
    static let controlStream = CBUUID(string: "7B83FFFD-9F77-4E5C-8064-AAE2C24838B9")

    // Device Information Service
    static let disService = CBUUID(string: "0000180A-0000-1000-8000-00805F9B34FB")
    static let disManufacturerName = CBUUID(string: "00002A29-0000-1000-8000-00805F9B34FB")
    static let disModelNumber = CBUUID(string: "00002A24-0000-1000-8000-00805F9B34FB")

    static let allPump: [CBUUID] = [
        currentStatus, qualifyingEvents, historyLog, authorization, control, controlStream,
    ]
}

/// Everything the packetizer needs to frame + sign an outgoing response.
struct TandemMobiResponse {
    let opCode: UInt8
    let characteristic: CBUUID
    let signed: Bool
    let cargo: Data
}

/// Static metadata for a response the simulator can emit, keyed by the
/// characteristic it travels on (opcodes intentionally overlap across
/// characteristics, so we never key by opcode alone).
struct TandemMobiResponseSpec {
    let opCode: UInt8
    let characteristic: CBUUID
    let signed: Bool
}

/// Response opcode registry built from TandemKit's MessageRegistry. Keys are
/// (characteristic, responseOpCode).
enum TandemMobiRegistry {
    static let authorization = TandemMobiCharacteristic.authorization
    static let currentStatus = TandemMobiCharacteristic.currentStatus
    static let control = TandemMobiCharacteristic.control

    static let all: [String: TandemMobiResponseSpec] = Dictionary(uniqueKeysWithValues: [
        // Authentication
        spec(authorization, 17, false), // CentralChallengeResponse
        spec(authorization, 19, false), // PumpChallengeResponse
        spec(authorization, 33, false), // Jpake1aResponse
        spec(authorization, 35, false), // Jpake1bResponse
        spec(authorization, 37, false), // Jpake2Response
        spec(authorization, 39, false), // Jpake3SessionKeyResponse
        spec(authorization, 41, false), // Jpake4KeyConfirmationResponse

        // CurrentStatus
        spec(currentStatus, 33, false), // ApiVersionResponse
        spec(currentStatus, 37, false), // InsulinStatusResponse
        spec(currentStatus, 41, false), // CurrentBasalStatusResponse
        spec(currentStatus, 43, false), // TempRateResponse
        spec(currentStatus, 45, false), // CurrentBolusStatusResponse
        spec(currentStatus, 55, false), // TimeSinceResetResponse
        spec(currentStatus, 59, false), // HistoryLogStatusResponse
        spec(currentStatus, 87, false), // PumpGlobalsResponse
        spec(currentStatus, 133, false), // PumpVersionBResponse
        spec(currentStatus, 139, false), // BasalLimitSettingsResponse
        spec(currentStatus, 141, false), // GlobalMaxBolusSettingsResponse
        spec(currentStatus, 145, false), // CurrentBatteryV2Response
        spec(currentStatus, 191, false), // CGMStatusV2Response

        // Control (all signed)
        spec(control, 135, true), // SetMaxBolusLimitResponse
        spec(control, 137, true), // SetMaxBasalLimitResponse
        spec(control, 155, true), // ResumePumpingResponse
        spec(control, 157, true), // SuspendPumpingResponse
        spec(control, 159, true), // InitiateBolusResponse
        spec(control, 161, true), // CancelBolusResponse
        spec(control, 163, true), // BolusPermissionResponse
        spec(control, 165, true), // SetTempRateResponse
        spec(control, 167, true), // StopTempRateResponse
        spec(control, 185, true), // DismissNotificationResponse
        spec(control, 205, true), // SetModesResponse
        spec(control, 207, true), // SetSleepScheduleResponse
        spec(control, 211, true), // SetQuickBolusSettingsResponse
        spec(control, 215, true), // ChangeTimeDateResponse
        spec(control, 241, true), // BolusPermissionReleaseResponse
        spec(control, 251, true), // AdditionalBolusResponse
    ])

    private static func spec(_ characteristic: CBUUID, _ opCode: UInt8, _ signed: Bool) -> (String, TandemMobiResponseSpec) {
        (key(characteristic, opCode), TandemMobiResponseSpec(opCode: opCode, characteristic: characteristic, signed: signed))
    }

    static func key(_ characteristic: CBUUID, _ opCode: UInt8) -> String {
        characteristic.uuidString + "-" + String(opCode)
    }

    static func spec(for characteristic: CBUUID, opCode: UInt8) -> TandemMobiResponseSpec? {
        all[key(characteristic, opCode)]
    }
}
