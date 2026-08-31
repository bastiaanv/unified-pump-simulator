import Foundation

/// Link tier configuration (see plan §4.6).
///
/// - **Tier A (default)**: transparent/secure link. The pump walks the handshake
///   shape (`0x101 → 0x102 → 0x103 → 0x104`) without real crypto and accepts the
///   `0x107` passkey when it matches `state.passkey`. After that the encrypted
///   characteristics carry plaintext CCMP frames (framed with a 1-byte seq).
///   This is enough to exercise the whole therapy surface.
/// - **Tier B**: genuine TLS 1.3 mTLS server. Not implemented — blocked by PKI
///   (no Medtronic pump private key). Left as a stub.
enum MiniMedLinkTier {
    case transparent // Tier A
    case tls // Tier B (stub)
}

/// Secure-link handshake state machine (`docs/11`):
/// `idle → clientHello → clientFinished → verify → established`.
/// Returns the CCMP responses the pump must send for each inbound message.
final class SecureLinkHandshake {
    enum Phase {
        case idle
        case waitingClientFinished
        case verify
        case established
    }

    private(set) var phase: Phase = .idle
    let tier: MiniMedLinkTier

    init(tier: MiniMedLinkTier = .transparent) {
        self.tier = tier
    }

    /// Handle an inbound CCMP payload addressed to the secure-link, producing any
    /// outbound response frames `(messageId, payload)`.
    func handle(messageID: UInt16, payload: Data, passkey: String) throws -> [(UInt16, Data)] {
        switch messageID {
        case CcmpMsgID.clientHello.rawValue:
            // 0x101 app → pump. Respond with a ServerHello record (0x102).
            phase = .waitingClientFinished
            // Tier A: the "ServerHello" is an opaque echo record so a test client can
            // keep walking the handshake. Tier B would produce a real TLS record here.
            return [(CcmpMsgID.serverHello.rawValue, serverHelloRecord(payload))]

        case CcmpMsgID.clientFinished.rawValue:
            // 0x103 app → pump. Respond with a ServerFinished record (0x104).
            phase = .verify
            return [(CcmpMsgID.serverFinished.rawValue, serverFinishedRecord(payload))]

        case CcmpMsgID.authError.rawValue:
            // 0x105 app revokes the link.
            phase = .idle
            return []

        case CcmpMsgID.passkey.rawValue:
            // 0x107 → 0x210 passkey verify. Response status byte: 1=valid, 2=invalid.
            phase = .established
            let expected = Data(passkey.utf8)
            let status: UInt8 = payload == expected ? 1 : 2
            return [(CcmpMsgID.passkeyRsp.rawValue, Data([status]))]

        default:
            return []
        }
    }

    var isEstablished: Bool {
        phase == .established
    }

    func reset() {
        phase = .idle
    }

    /// Tier A: The record bytes are opaque. We reflect the inbound nonce/payload as a
    /// stand-in so the byte-format stays correct without real TLS.
    private func serverHelloRecord(_ clientHello: Data) -> Data {
        let echoed = clientHello.isEmpty ? Data() : clientHello.prefix(clientHello.count)
        return Data([0x02]) + echoed // placeholder ServerHello record
    }

    private func serverFinishedRecord(_ clientFinished: Data) -> Data {
        Data([0x02]) + clientFinished
    }
}
