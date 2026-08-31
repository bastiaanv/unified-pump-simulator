import Foundation

/// Builders for CURRENT_STATUS responses (none are signed). Opcodes match the
/// registry in `TandemMobiMessage.swift`.
enum TandemMobiStatusResponses {
    private static let currentStatus = TandemMobiCharacteristic.currentStatus

    static func timeSinceReset(currentTime: UInt32, timeSinceReset: UInt32) -> TandemMobiResponse {
        let cargo = TandemMobiBytes.combine(
            TandemMobiBytes.u32(currentTime),
            TandemMobiBytes.u32(timeSinceReset)
        )
        return TandemMobiResponse(opCode: 55, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func apiVersion(major: UInt16 = 3, minor: UInt16 = 5) -> TandemMobiResponse {
        let cargo = TandemMobiBytes.combine(TandemMobiBytes.u16(major), TandemMobiBytes.u16(minor))
        return TandemMobiResponse(opCode: 33, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func pumpVersionB(serialNumber: UInt32) -> TandemMobiResponse {
        let softwareName = TandemMobiBytes.pad(Data("MobiSoftware".utf8), to: 20)
        let modelNumber: UInt32 = 1_004_000 // PumpModel.MOBI
        let pumpRevision = TandemMobiBytes.pad(Data("1.0.0".utf8), to: 8)
        let pcbRevision = TandemMobiBytes.pad(Data("1.0".utf8), to: 8)
        let cargo = TandemMobiBytes.combine(
            softwareName,
            TandemMobiBytes.u32(0), // configurationBitsA
            TandemMobiBytes.u32(0), // configurationBitsB
            TandemMobiBytes.u32(serialNumber),
            TandemMobiBytes.u32(modelNumber),
            pumpRevision,
            TandemMobiBytes.u32(0), // pcbPartNumberA
            TandemMobiBytes.u32(0), // pcbSerialNumberA
            pcbRevision
        )
        return TandemMobiResponse(opCode: 133, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func currentBatteryV2(percent: UInt8) -> TandemMobiResponse {
        let cargo = TandemMobiBytes.combine(
            TandemMobiBytes.u8(0), // currentBatteryAbc
            TandemMobiBytes.u8(percent),
            TandemMobiBytes.u8(0), // chargingStatus
            TandemMobiBytes.u16(0),
            TandemMobiBytes.u16(0),
            TandemMobiBytes.u16(0),
            TandemMobiBytes.u16(0)
        )
        return TandemMobiResponse(opCode: 145, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func currentBasalStatus(
        profileRateMilliunits: UInt32,
        currentRateMilliunits: UInt32,
        modifiedBitmask: UInt8
    ) -> TandemMobiResponse {
        let cargo = TandemMobiBytes.combine(
            TandemMobiBytes.u32(profileRateMilliunits),
            TandemMobiBytes.u32(currentRateMilliunits),
            TandemMobiBytes.u8(modifiedBitmask)
        )
        return TandemMobiResponse(opCode: 41, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func currentBolusStatus(
        statusId: UInt8 = 0,
        bolusId: UInt16 = 0,
        requestedMilliunits: UInt32 = 0
    ) -> TandemMobiResponse {
        let cargo = TandemMobiBytes.combine(
            TandemMobiBytes.u8(statusId),
            TandemMobiBytes.u16(bolusId),
            Data([0x00, 0x00]),
            TandemMobiBytes.u32(TandemMobiDates.currentTimeSinceJan12008()),
            TandemMobiBytes.u32(requestedMilliunits),
            TandemMobiBytes.u8(0),
            TandemMobiBytes.u8(0)
        )
        return TandemMobiResponse(opCode: 45, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func basalLimitSettings(limitMilliunits: UInt32, defaultMilliunits: UInt32) -> TandemMobiResponse {
        let cargo = TandemMobiBytes.combine(TandemMobiBytes.u32(limitMilliunits), TandemMobiBytes.u32(defaultMilliunits))
        return TandemMobiResponse(opCode: 139, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func globalMaxBolusSettings(maxMilliunits: UInt16, defaultMilliunits: UInt16) -> TandemMobiResponse {
        let cargo = TandemMobiBytes.combine(TandemMobiBytes.u16(maxMilliunits), TandemMobiBytes.u16(defaultMilliunits))
        return TandemMobiResponse(opCode: 141, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func pumpGlobals() -> TandemMobiResponse {
        var cargo = Data()
        cargo.append(TandemMobiBytes.u8(0)) // quickBolusEnabled
        cargo.append(TandemMobiBytes.u16(0)) // quickBolusIncrementUnits
        cargo.append(TandemMobiBytes.u16(0)) // quickBolusIncrementCarbs
        for _ in 0 ..< 9 {
            cargo.append(TandemMobiBytes.u8(0))
        }
        return TandemMobiResponse(opCode: 87, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func insulinStatus(insulinUnitsX100: UInt16 = 0) -> TandemMobiResponse {
        let cargo = TandemMobiBytes.combine(
            TandemMobiBytes.u16(insulinUnitsX100),
            TandemMobiBytes.u8(0),
            TandemMobiBytes.u8(0)
        )
        return TandemMobiResponse(opCode: 37, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func cgmStatusV2() -> TandemMobiResponse {
        var cargo = Data()
        cargo.append(TandemMobiBytes.u8(0)) // sessionStateId (stopped)
        cargo.append(TandemMobiBytes.u32(0)) // lastCalibrationTimestamp
        cargo.append(TandemMobiBytes.u32(0)) // sensorStartedTimestamp
        cargo.append(TandemMobiBytes.u8(0)) // transmitterBatteryStatusId
        cargo.append(TandemMobiBytes.u32(0)) // sessionDurationSeconds
        cargo.append(TandemMobiBytes.u32(0)) // sessionTimeRemainingSeconds
        cargo.append(TandemMobiBytes.u8(0)) // cgmSensorTypeId
        cargo.append(TandemMobiBytes.u8(0)) // gracePeriod
        return TandemMobiResponse(opCode: 191, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func historyLogStatus() -> TandemMobiResponse {
        let cargo = TandemMobiBytes.combine(TandemMobiBytes.u32(0), TandemMobiBytes.u32(0), TandemMobiBytes.u32(0))
        return TandemMobiResponse(opCode: 59, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func tempRate(
        active: UInt8 = 0,
        percentage: UInt8 = 0,
        startTime: UInt32 = 0,
        duration: UInt32 = 0
    ) -> TandemMobiResponse {
        let cargo = TandemMobiBytes.combine(
            TandemMobiBytes.u8(active),
            TandemMobiBytes.u8(percentage),
            TandemMobiBytes.u32(startTime),
            TandemMobiBytes.u32(duration)
        )
        return TandemMobiResponse(opCode: 43, characteristic: currentStatus, signed: false, cargo: cargo)
    }
}
