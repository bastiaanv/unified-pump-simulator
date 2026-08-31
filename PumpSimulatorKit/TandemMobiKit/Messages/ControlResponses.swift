import Foundation

/// Builders for CONTROL responses (all signed). Opcodes match the registry.
enum TandemMobiControlResponses {
    private static let control = TandemMobiCharacteristic.control

    static func ack(_ opCode: UInt8, status: UInt8 = 0) -> TandemMobiResponse {
        TandemMobiResponse(opCode: opCode, characteristic: control, signed: true, cargo: TandemMobiBytes.u8(status))
    }

    static func initiateBolus(status: UInt8 = 0, bolusId: UInt16, statusTypeId: UInt8 = 0) -> TandemMobiResponse {
        let cargo = TandemMobiBytes.combine(
            TandemMobiBytes.u8(status),
            TandemMobiBytes.u16(bolusId),
            Data([0x00, 0x00]),
            TandemMobiBytes.u8(statusTypeId)
        )
        return TandemMobiResponse(opCode: 159, characteristic: control, signed: true, cargo: cargo)
    }

    static func cancelBolus(statusId: UInt8 = 0, bolusId: UInt16, reasonId: UInt8 = 0) -> TandemMobiResponse {
        let cargo = TandemMobiBytes.combine(
            TandemMobiBytes.u8(statusId),
            TandemMobiBytes.u16(bolusId),
            TandemMobiBytes.u8(reasonId),
            Data([0x00])
        )
        return TandemMobiResponse(opCode: 161, characteristic: control, signed: true, cargo: cargo)
    }

    static func bolusPermission(status: UInt8 = 0, bolusId: UInt16, nackReasonId: UInt8 = 0) -> TandemMobiResponse {
        let cargo = TandemMobiBytes.combine(
            TandemMobiBytes.u8(status),
            TandemMobiBytes.u16(bolusId),
            Data([0x00, 0x00]),
            TandemMobiBytes.u8(nackReasonId)
        )
        return TandemMobiResponse(opCode: 163, characteristic: control, signed: true, cargo: cargo)
    }

    static func additionalBolus(status: UInt8 = 0, bolusId: UInt16, reserve: UInt16) -> TandemMobiResponse {
        let cargo = TandemMobiBytes.combine(
            TandemMobiBytes.u8(status),
            TandemMobiBytes.u16(bolusId),
            TandemMobiBytes.u16(reserve)
        )
        return TandemMobiResponse(opCode: 251, characteristic: control, signed: true, cargo: cargo)
    }

    static func setTempRate(status: UInt8 = 0, tempRateId: UInt16 = 0) -> TandemMobiResponse {
        let cargo = TandemMobiBytes.combine(TandemMobiBytes.u8(status), TandemMobiBytes.u16(tempRateId))
        return TandemMobiResponse(opCode: 165, characteristic: control, signed: true, cargo: cargo)
    }

    static func stopTempRate(status: UInt8 = 0, tempRateId: UInt16 = 0) -> TandemMobiResponse {
        let cargo = TandemMobiBytes.combine(TandemMobiBytes.u8(status), TandemMobiBytes.u16(tempRateId))
        return TandemMobiResponse(opCode: 167, characteristic: control, signed: true, cargo: cargo)
    }
}
