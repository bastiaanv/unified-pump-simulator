import Foundation

/// Builders for AUTHORIZATION responses (never signed). These handle the legacy
/// 16-character pairing flow; a Mobi central normally uses JPAKE instead, but we
/// still answer so an older driver path can complete.
enum TandemAuthResponses {
    private static let authorization = TandemCharacteristic.authorization

    /// Given a `CentralChallengeRequest` cargo `[appInstanceId u16][challenge 8]`,
    /// produce the matching `CentralChallengeResponse`
    /// `[appInstanceId u16][hash 20][hmacKey 8]`.
    static func centralChallenge(requestCargo: Data) -> TandemResponse {
        let appInstanceId = requestCargo.count >= 2 ? TandemBytes.readU16(requestCargo, 0) : 0
        let challenge = requestCargo.count >= 10 ? requestCargo.subdata(in: 2 ..< 10) : Data(repeating: 0, count: 8)

        let hmacKey = TandemRandom.bytes(8)
        let hash = TandemHmac.hmacSha1(data: challenge, key: hmacKey)

        let cargo = TandemBytes.combine(TandemBytes.u16(appInstanceId), hash, hmacKey)
        return TandemResponse(opCode: 17, characteristic: authorization, signed: false, cargo: cargo)
    }

    /// Given a `PumpChallengeRequest` cargo `[appInstanceId u16][pumpChallengeHash 20]`,
    /// produce the matching `PumpChallengeResponse` `[appInstanceId u16][success 1]`.
    static func pumpChallenge(requestCargo: Data) -> TandemResponse {
        let appInstanceId = requestCargo.count >= 2 ? TandemBytes.readU16(requestCargo, 0) : 0
        let cargo = TandemBytes.combine(TandemBytes.u16(appInstanceId), TandemBytes.u8(1))
        return TandemResponse(opCode: 19, characteristic: authorization, signed: false, cargo: cargo)
    }
}
