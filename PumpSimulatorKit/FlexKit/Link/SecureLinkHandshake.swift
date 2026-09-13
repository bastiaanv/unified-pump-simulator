import Foundation

/// Link tier configuration (see plan §4.6).
///
/// - **Tier A (`transparent`)**: transparent/secure link. The pump walks the
///   handshake shape (`0x101 → 0x102 → 0x103 → 0x104`) with an opaque echo and
///   accepts the `0x107` passkey when it matches `state.passkey`. After that the
///   encrypted characteristics carry plaintext CCMP frames (framed with a 1-byte
///   seq). This is enough to exercise the whole therapy surface with a non-TLS
///   test client; it cannot satisfy the real FlexKit client, which always drives
///   mbedTLS.
/// - **Tier B (`tls`)**: genuine TLS 1.3 server driven by `MiniMedTLSServer`.
///   Post-handshake traffic is protected exactly as FlexKit's `SecureGattClient`
///   expects (`[seq][TLS(CCMP frame)]`).
enum MiniMedLinkTier {
    case transparent // Tier A
    case tls // Tier B
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

    /// Live mbedTLS server for the `tls` tier; `nil` for `transparent` or before
    /// a ClientHello arrives. A fresh session is created per handshake because
    /// mbedTLS contexts are not reusable.
    private var tls: MiniMedTLSServer?
    private let serverCertPEM: Data
    private let serverKeyPEM: Data

    init(
        tier: MiniMedLinkTier = .transparent,
        serverCertPEM: Data = Data(),
        serverKeyPEM: Data = Data()
    ) {
        self.tier = tier
        self.serverCertPEM = serverCertPEM
        self.serverKeyPEM = serverKeyPEM
    }

    /// Exposed so the GATT manager can run post-handshake encrypt/decrypt.
    var tlsSession: MiniMedTLSServer? { tls }

    /// True once the TLS handshake completed (Tier B). The manager gates
    /// encryption on this rather than on `isEstablished`, because the passkey
    /// (`0x0107`) is already TLS-encrypted *before* activation.
    var isTLSHandshakeComplete: Bool { tls?.handshakeComplete ?? false }

    /// Handle an inbound CCMP payload addressed to the secure-link, producing any
    /// outbound response frames `(messageId, payload)`.
    func handle(messageID: UInt16, payload: Data, passkey: String) throws -> [(UInt16, Data)] {
        switch messageID {
        case CcmpMsgID.clientHello.rawValue:
            // 0x101 app → pump. Respond with the server flight (0x102).
            phase = .waitingClientFinished
            switch tier {
            case .transparent:
                return [(CcmpMsgID.serverHello.rawValue, echoRecord(payload))]
            case .tls:
                let server = try MiniMedTLSServer(
                    serverCertPEM: serverCertPEM,
                    serverKeyPEM: serverKeyPEM
                )
                tls = server
                let flight = try server.feed(payload)
                return [(CcmpMsgID.serverHello.rawValue, flight)]
            }

        case CcmpMsgID.clientFinished.rawValue:
            // 0x103 app → pump. Respond with any residual server records (0x104).
            phase = .verify
            switch tier {
            case .transparent:
                return [(CcmpMsgID.serverFinished.rawValue, echoRecord(payload))]
            case .tls:
                guard let tls else { return [] }
                let remainder = try tls.feed(payload)
                return [(CcmpMsgID.serverFinished.rawValue, remainder)]
            }

        case CcmpMsgID.authError.rawValue:
            // 0x105 app revokes the link.
            tls = nil
            phase = .idle
            return []

        case CcmpMsgID.passkey.rawValue:
            // 0x107 → 0x210 passkey verify. Response status byte: 1=valid, 2=invalid.
            // In the TLS tier the request payload is TLS application ciphertext
            // (FlexKit's `sendEncrypted`); decrypt before comparing.
            phase = .established
            var plaintext = payload
            if case .tls = tier, let tls {
                plaintext = try tls.decrypt(payload)
            }
            let expected = Data(passkey.utf8)
            let status: UInt8 = plaintext == expected ? 1 : 2
            return [(CcmpMsgID.passkeyRsp.rawValue, Data([status]))]

        default:
            return []
        }
    }

    var isEstablished: Bool {
        phase == .established
    }

    func reset() {
        tls = nil
        phase = .idle
    }

    /// Tier A: the record bytes are opaque. Echo the inbound record so a non-TLS
    /// test client can walk the handshake shape. Never used by the real client.
    private func echoRecord(_ inbound: Data) -> Data {
        inbound
    }
}
