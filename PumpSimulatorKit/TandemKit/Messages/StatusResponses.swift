import Foundation

/// Builders for CURRENT_STATUS responses (none are signed). Opcodes match the
/// registry in `TandemMessage.swift`.
enum TandemStatusResponses {
    private static let currentStatus = TandemCharacteristic.currentStatus

    static func timeSinceReset(currentTime: UInt32, timeSinceReset: UInt32) -> TandemResponse {
        let cargo = TandemBytes.combine(
            TandemBytes.u32(currentTime),
            TandemBytes.u32(timeSinceReset)
        )
        return TandemResponse(opCode: 55, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func apiVersion(major: UInt16 = 3, minor: UInt16 = 5) -> TandemResponse {
        let cargo = TandemBytes.combine(TandemBytes.u16(major), TandemBytes.u16(minor))
        return TandemResponse(opCode: 33, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func pumpVersionB(serialNumber: UInt32) -> TandemResponse {
        let softwareName = TandemBytes.pad(Data("MobiSoftware".utf8), to: 20)
        let modelNumber: UInt32 = 1_004_000 // PumpModel.MOBI
        let pumpRevision = TandemBytes.pad(Data("1.0.0".utf8), to: 8)
        let pcbRevision = TandemBytes.pad(Data("1.0".utf8), to: 8)
        let cargo = TandemBytes.combine(
            softwareName,
            TandemBytes.u32(0), // configurationBitsA
            TandemBytes.u32(0), // configurationBitsB
            TandemBytes.u32(serialNumber),
            TandemBytes.u32(modelNumber),
            pumpRevision,
            TandemBytes.u32(0), // pcbPartNumberA
            TandemBytes.u32(0), // pcbSerialNumberA
            pcbRevision
        )
        return TandemResponse(opCode: 133, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func currentBatteryV2(percent: UInt8) -> TandemResponse {
        let cargo = TandemBytes.combine(
            TandemBytes.u8(0), // currentBatteryAbc
            TandemBytes.u8(percent),
            TandemBytes.u8(0), // chargingStatus
            TandemBytes.u16(0),
            TandemBytes.u16(0),
            TandemBytes.u16(0),
            TandemBytes.u16(0)
        )
        return TandemResponse(opCode: 145, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func currentBasalStatus(
        profileRateMilliunits: UInt32,
        currentRateMilliunits: UInt32,
        modifiedBitmask: UInt8
    ) -> TandemResponse {
        let cargo = TandemBytes.combine(
            TandemBytes.u32(profileRateMilliunits),
            TandemBytes.u32(currentRateMilliunits),
            TandemBytes.u8(modifiedBitmask)
        )
        return TandemResponse(opCode: 41, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func currentBolusStatus(
        statusId: UInt8 = 0,
        bolusId: UInt16 = 0,
        requestedMilliunits: UInt32 = 0
    ) -> TandemResponse {
        let cargo = TandemBytes.combine(
            TandemBytes.u8(statusId),
            TandemBytes.u16(bolusId),
            Data([0x00, 0x00]),
            TandemBytes.u32(TandemDates.currentTimeSinceJan12008()),
            TandemBytes.u32(requestedMilliunits),
            TandemBytes.u8(0),
            TandemBytes.u8(0)
        )
        return TandemResponse(opCode: 45, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func basalLimitSettings(limitMilliunits: UInt32, defaultMilliunits: UInt32) -> TandemResponse {
        let cargo = TandemBytes.combine(TandemBytes.u32(limitMilliunits), TandemBytes.u32(defaultMilliunits))
        return TandemResponse(opCode: 139, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func globalMaxBolusSettings(maxMilliunits: UInt16, defaultMilliunits: UInt16) -> TandemResponse {
        let cargo = TandemBytes.combine(TandemBytes.u16(maxMilliunits), TandemBytes.u16(defaultMilliunits))
        return TandemResponse(opCode: 141, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func pumpGlobals() -> TandemResponse {
        var cargo = Data()
        cargo.append(TandemBytes.u8(0)) // quickBolusEnabled
        cargo.append(TandemBytes.u16(0)) // quickBolusIncrementUnits
        cargo.append(TandemBytes.u16(0)) // quickBolusIncrementCarbs
        for _ in 0 ..< 9 {
            cargo.append(TandemBytes.u8(0))
        }
        return TandemResponse(opCode: 87, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func insulinStatus(insulinUnitsX100: UInt16 = 0) -> TandemResponse {
        let cargo = TandemBytes.combine(
            TandemBytes.u16(insulinUnitsX100),
            TandemBytes.u8(0),
            TandemBytes.u8(0)
        )
        return TandemResponse(opCode: 37, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func cgmStatusV2() -> TandemResponse {
        var cargo = Data()
        cargo.append(TandemBytes.u8(0)) // sessionStateId (stopped)
        cargo.append(TandemBytes.u32(0)) // lastCalibrationTimestamp
        cargo.append(TandemBytes.u32(0)) // sensorStartedTimestamp
        cargo.append(TandemBytes.u8(0)) // transmitterBatteryStatusId
        cargo.append(TandemBytes.u32(0)) // sessionDurationSeconds
        cargo.append(TandemBytes.u32(0)) // sessionTimeRemainingSeconds
        cargo.append(TandemBytes.u8(0)) // cgmSensorTypeId
        cargo.append(TandemBytes.u8(0)) // gracePeriod
        return TandemResponse(opCode: 191, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func historyLogStatus() -> TandemResponse {
        let cargo = TandemBytes.combine(TandemBytes.u32(0), TandemBytes.u32(0), TandemBytes.u32(0))
        return TandemResponse(opCode: 59, characteristic: currentStatus, signed: false, cargo: cargo)
    }

    static func tempRate(
        active: UInt8 = 0,
        percentage: UInt8 = 0,
        startTime: UInt32 = 0,
        duration: UInt32 = 0
    ) -> TandemResponse {
        let cargo = TandemBytes.combine(
            TandemBytes.u8(active),
            TandemBytes.u8(percentage),
            TandemBytes.u32(startTime),
            TandemBytes.u32(duration)
        )
        return TandemResponse(opCode: 43, characteristic: currentStatus, signed: false, cargo: cargo)
    }
}
