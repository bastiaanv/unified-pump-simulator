import Foundation

/// CCMP message ids the pump must answer (consolidated from `docs/4,7,9,14`,
/// `packets/02` and the reference `CCMPProtocol.swift`).
enum CcmpMsgID: UInt16 {
    // TLS handshake
    case clientHello = 0x0101 // app → pump
    case serverHello = 0x0102 // pump → app
    case clientFinished = 0x0103 // app → pump
    case serverFinished = 0x0104 // pump → app
    case authError = 0x0105 // app → pump
    case passkey = 0x0107 // app → pump
    case passkeyRsp = 0x0210 // pump → app

    // MTS transport ACK / key-confirmation (consume below app layers)
    case mtsDataAck = 0x0204
    case mtsStreamAck = 0x0208

    // Pump-certificate get/set
    case certGetReq = 0x0001
    case certGetReply = 0x0004
    case certSetReq = 0x0003
    case certSetReply = 0x0008

    // FOTA (0x0208 also appears as an MTS transport ACK — see mtsStreamAck)
    case fotaStatusReq = 0x0201
    case fotaInstall = 0x0207
    case fotaStatusRsp = 0x0414
    case fotaInstallRsp = 0x0412
    case fotaCancelRsp = 0x0416

    // Therapy / status command messages (unpinned message-ids — see MiniMedKitLinkConfig)
    case commandControl = 0x01A0 // IDD command control traffic
    case srcp = 0x01B0 // status control point
    case deviceTime = 0x01C0 // device-time control point
    case racp = 0x01D0 // record / history
}

/// CCMP format-0 wire encoder/decoder (`packets/01 §1`).
///
/// Canonical wire layout (LITTLE-ENDIAN — ground truth from `packets/00_README`):
/// ```
/// [0]      format        uint8       = 0
/// [1..2]   messageId     uint16  LE
/// [3..6]   payloadLength uint32  LE
/// [7]      noncePresence uint8       (bit1 → 16B senderNonce, bit0 → 16B recipientNonce)
/// [8..]    nonces        (per flag)
/// [...]    data          payloadLength bytes
/// ```
enum CCMPFormat0 {
    struct Frame {
        let messageID: UInt16
        let payload: Data
    }

    /// Encode a format-0 frame (no nonce unless `senderNonce` non-empty).
    static func encode(messageID: UInt16, payload: Data, senderNonce: [UInt8] = []) -> Data {
        var out = Data()
        out.append(0) // format = 0
        out.append(messageID.miniMedData()) // id LE
        out.append(UInt32(payload.count).miniMedData()) // length LE
        let presence: UInt8 = senderNonce.isEmpty ? 0 : 0x02
        out.append(presence)
        if !senderNonce.isEmpty {
            out.append(contentsOf: senderNonce)
        }
        out.append(payload)
        return out
    }

    /// Decode a format-0 frame.
    static func decode(_ data: Data) throws -> Frame {
        guard data.count >= 8 else {
            throw MiniMedError.protocolError("CCMP frame too short")
        }
        let format = data[0]
        guard format == 0 else {
            throw MiniMedError.protocolError("expected format-0, got \(format)")
        }
        let messageID = data.miniMedUInt16(1)
        let payloadLength = Int(data.miniMedUInt32(3))
        let presence = data[7]

        var cursor = 8
        if presence & 0x02 != 0 {
            cursor += 16
        } // sender nonce
        if presence & 0x01 != 0 {
            cursor += 16
        } // recipient nonce

        guard cursor + payloadLength <= data.count else {
            throw MiniMedError.protocolError("CCMP payload length overflow")
        }
        let payload = data.subdata(in: cursor ..< (cursor + payloadLength))
        return Frame(messageID: messageID, payload: payload)
    }
}
