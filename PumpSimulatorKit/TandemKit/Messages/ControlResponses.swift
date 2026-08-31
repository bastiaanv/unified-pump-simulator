import Foundation

/// Builders for CONTROL responses (all signed). Opcodes match the registry.
enum TandemControlResponses {
    private static let control = TandemCharacteristic.control

    static func ack(_ opCode: UInt8, status: UInt8 = 0) -> TandemResponse {
        TandemResponse(opCode: opCode, characteristic: control, signed: true, cargo: TandemBytes.u8(status))
    }

    static func initiateBolus(status: UInt8 = 0, bolusId: UInt16, statusTypeId: UInt8 = 0) -> TandemResponse {
        let cargo = TandemBytes.combine(
            TandemBytes.u8(status),
            TandemBytes.u16(bolusId),
            Data([0x00, 0x00]),
            TandemBytes.u8(statusTypeId)
        )
        return TandemResponse(opCode: 159, characteristic: control, signed: true, cargo: cargo)
    }

    static func cancelBolus(statusId: UInt8 = 0, bolusId: UInt16, reasonId: UInt8 = 0) -> TandemResponse {
        let cargo = TandemBytes.combine(
            TandemBytes.u8(statusId),
            TandemBytes.u16(bolusId),
            TandemBytes.u8(reasonId),
            Data([0x00])
        )
        return TandemResponse(opCode: 161, characteristic: control, signed: true, cargo: cargo)
    }

    static func bolusPermission(status: UInt8 = 0, bolusId: UInt16, nackReasonId: UInt8 = 0) -> TandemResponse {
        let cargo = TandemBytes.combine(
            TandemBytes.u8(status),
            TandemBytes.u16(bolusId),
            Data([0x00, 0x00]),
            TandemBytes.u8(nackReasonId)
        )
        return TandemResponse(opCode: 163, characteristic: control, signed: true, cargo: cargo)
    }

    static func additionalBolus(status: UInt8 = 0, bolusId: UInt16, reserve: UInt16) -> TandemResponse {
        let cargo = TandemBytes.combine(
            TandemBytes.u8(status),
            TandemBytes.u16(bolusId),
            TandemBytes.u16(reserve)
        )
        return TandemResponse(opCode: 251, characteristic: control, signed: true, cargo: cargo)
    }

    static func setTempRate(status: UInt8 = 0, tempRateId: UInt16 = 0) -> TandemResponse {
        let cargo = TandemBytes.combine(TandemBytes.u8(status), TandemBytes.u16(tempRateId))
        return TandemResponse(opCode: 165, characteristic: control, signed: true, cargo: cargo)
    }

    static func stopTempRate(status: UInt8 = 0, tempRateId: UInt16 = 0) -> TandemResponse {
        let cargo = TandemBytes.combine(TandemBytes.u8(status), TandemBytes.u16(tempRateId))
        return TandemResponse(opCode: 167, characteristic: control, signed: true, cargo: cargo)
    }
}
