import CMbedTLS
import Foundation

/// A minimal thread-safe byte queue shared by mbedTLS's BIO callbacks and the
/// caller. Mirrors FlexKit's `IoQueue` (`MBedTLSSession.swift`); the two repos
/// share no module, so it is copied here rather than imported.
final class IoQueue {
    private var buffer = Data()
    private let lock = NSLock()

    var isEmpty: Bool { lock.withLock { buffer.isEmpty } }

    func write(_ bytes: Data) {
        lock.withLock { buffer.append(contentsOf: bytes) }
    }

    func readAll() -> Data {
        lock.withLock {
            defer { buffer.removeAll(keepingCapacity: true) }
            return Data(buffer)
        }
    }

    func read(count: Int) -> Data {
        lock.withLock {
            let n = min(count, buffer.count)
            let out = Data(buffer.prefix(n))
            buffer.removeFirst(n)
            return out
        }
    }

    func clear() {
        lock.withLock { buffer.removeAll(keepingCapacity: true) }
    }
}

/// TLS 1.3 server over the same in-memory `IoQueue` + `mbedtls_ssl_set_bio`
/// pattern FlexKit's `MBedTLSSession` uses on the client side.
///
/// Configuration deliberately mirrors the client pin (`MBedTLSSession.swift`) so
/// the two sides cannot drift:
/// - TLS 1.3 only (`min == max == MBEDTLS_SSL_VERSION_TLS1_3`).
/// - Single cipher `MBEDTLS_TLS1_3_AES_128_GCM_SHA256` (`0x1301`).
/// - Ephemeral key exchange, ECDSA P-256 certificate.
///
/// Client authentication is `VERIFY_NONE` for the simulator milestone: FlexKit
/// presents a self-signed client certificate that the test CA does not issue.
/// See `real-tls13-server-plan.md` §T3.
final class MiniMedTLSServer {
    static let wantRead = Int32(MBEDTLS_ERR_SSL_WANT_READ)
    static let wantWrite = Int32(MBEDTLS_ERR_SSL_WANT_WRITE)
    static let maxMsgSize = 16384

    /// Set once `mbedtls_ssl_handshake` has returned success. Callers gate the
    /// post-handshake encrypt/decrypt path on this, not on the CCMP phase.
    private(set) var handshakeComplete = false

    private var ciphersuites: [Int32] = [Int32(MBEDTLS_TLS1_3_AES_128_GCM_SHA256), 0]

    private var ssl = mbedtls_ssl_context()
    private var conf = mbedtls_ssl_config()
    private var entropy = mbedtls_entropy_context()
    private var ctrDrbg = mbedtls_ctr_drbg_context()
    private var serverCrt = mbedtls_x509_crt()
    private var serverKey = mbedtls_pk_context()

    private let recvQueue = IoQueue()
    private let sendQueue = IoQueue()
    private let logger = PumpManagerLogger(
        subsystem: "com.bastiaanv.flexkit",
        category: "MiniMedTLSServer"
    )

    init(serverCertPEM: Data, serverKeyPEM: Data) throws {
        mbedtls_ssl_init(&ssl)
        mbedtls_ssl_config_init(&conf)
        mbedtls_x509_crt_init(&serverCrt)
        mbedtls_pk_init(&serverKey)
        mbedtls_entropy_init(&entropy)
        mbedtls_ctr_drbg_init(&ctrDrbg)

        guard mbedtls_ctr_drbg_seed(&ctrDrbg, mbedtls_entropy_func, &entropy, nil, 0) == 0 else {
            logger.error("ctr_drbg_seed failed")
            throw MiniMedError.protocolError("server ctr_drbg_seed failed")
        }

        let certPEM = serverCertPEM + Data([0])
        let keyPEM = serverKeyPEM + Data([0])

        let certRC = certPEM.withUnsafeBytes { buffer in
            mbedtls_x509_crt_parse(
                &serverCrt,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                certPEM.count
            )
        }
        guard certRC == 0 else {
            logger.error("failed to parse server certificate (rc=\(certRC))")
            throw MiniMedError.protocolError("server cert parse failed (rc=\(certRC))")
        }

        let keyRC = keyPEM.withUnsafeBytes { buffer in
            mbedtls_pk_parse_key(
                &serverKey,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                keyPEM.count,
                nil,
                0,
                mbedtls_ctr_drbg_random,
                &ctrDrbg
            )
        }
        guard keyRC == 0 else {
            logger.error("failed to parse server private key (rc=\(keyRC))")
            throw MiniMedError.protocolError("server key parse failed (rc=\(keyRC))")
        }

        guard mbedtls_ssl_config_defaults(
            &conf,
            MBEDTLS_SSL_IS_SERVER,
            MBEDTLS_SSL_TRANSPORT_STREAM,
            MBEDTLS_SSL_PRESET_DEFAULT
        ) == 0
        else {
            logger.error("ssl_config_defaults failed")
            throw MiniMedError.protocolError("server ssl_config_defaults failed")
        }

        // Milestone 1: accept the client's self-signed cert without verifying.
        mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE)
        mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &ctrDrbg)
        mbedtls_ssl_conf_own_cert(&conf, &serverCrt, &serverKey)
        ciphersuites.withUnsafeBufferPointer { p in
            mbedtls_ssl_conf_ciphersuites(&conf, p.baseAddress)
        }
        mbedtls_ssl_conf_tls13_key_exchange_modes(
            &conf,
            Int32(MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_EPHEMERAL)
        )
        mbedtls_ssl_conf_min_tls_version(&conf, MBEDTLS_SSL_VERSION_TLS1_3)
        mbedtls_ssl_conf_max_tls_version(&conf, MBEDTLS_SSL_VERSION_TLS1_3)

        // No session tickets: their post-handshake records would surface as a
        // separate flight the simulator's one-shot encrypt/decrypt cannot drive.
        mbedtls_ssl_conf_session_tickets(&conf, MBEDTLS_SSL_SESSION_TICKETS_DISABLED)
        mbedtls_ssl_conf_new_session_tickets(&conf, 0)

        guard mbedtls_ssl_setup(&ssl, &conf) == 0 else {
            logger.error("ssl_setup failed")
            throw MiniMedError.protocolError("server ssl_setup failed")
        }

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        mbedtls_ssl_set_bio(
            &ssl,
            opaque,
            { p, buf, len in MiniMedTLSServer.sendCallbackBody(p, buf, len) },
            { p, buf, len in MiniMedTLSServer.recvCallbackBody(p, buf, len) },
            nil
        )
    }

    deinit {
        mbedtls_x509_crt_free(&serverCrt)
        mbedtls_pk_free(&serverKey)
        mbedtls_ssl_free(&ssl)
        mbedtls_ssl_config_free(&conf)
        mbedtls_ctr_drbg_free(&ctrDrbg)
        mbedtls_entropy_free(&entropy)
    }

    /// Stage inbound TLS records, then advance the handshake until mbedTLS needs
    /// more input. Returns the TLS records produced by this step (the server
    /// flight on ClientHello, usually empty on client Finished).
    @discardableResult func feed(_ records: Data) throws -> Data {
        recvQueue.write(records)
        return try advance()
    }

    /// Pump `mbedtls_ssl_handshake` until it completes or blocks on input.
    @discardableResult func advance() throws -> Data {
        var loops = 0
        while true {
            loops += 1
            let rc = mbedtls_ssl_handshake(&ssl)
            switch rc {
            case 0:
                handshakeComplete = true
                return sendQueue.readAll()
            case Self.wantRead:
                return sendQueue.readAll()
            case Self.wantWrite:
                guard loops < 32 else {
                    throw MiniMedError.protocolError("server handshake stalled on WANT_WRITE")
                }
                continue
            default:
                throw MiniMedError.protocolError("server handshake: \(errorString(rc))")
            }
        }
    }

    /// Post-handshake server -> client encryption: plaintext to TLS records.
    func encrypt(_ plaintext: Data) throws -> Data {
        sendQueue.clear()
        let n = plaintext.withUnsafeBytes { p in
            mbedtls_ssl_write(
                &ssl,
                p.bindMemory(to: UInt8.self).baseAddress,
                plaintext.count
            )
        }
        guard n == plaintext.count else {
            throw MiniMedError.protocolError("server ssl_write: \(errorString(n))")
        }
        return sendQueue.readAll()
    }

    /// Post-handshake client -> server decryption: TLS records to plaintext.
    func decrypt(_ ciphertext: Data) throws -> Data {
        recvQueue.write(ciphertext)
        var out = Data(repeating: 0, count: Self.maxMsgSize)
        let n = out.withUnsafeMutableBytes { p in
            mbedtls_ssl_read(&ssl, p.bindMemory(to: UInt8.self).baseAddress, Self.maxMsgSize)
        }
        guard n > 0 else {
            throw MiniMedError.protocolError("server ssl_read: \(errorString(n))")
        }
        return out.subdata(in: 0 ..< Int(n))
    }

    private static func sendCallbackBody(
        _ p: UnsafeMutableRawPointer?,
        _ buf: UnsafePointer<UInt8>?,
        _ len: Int
    ) -> Int32 {
        guard let p, let buf, len > 0 else { return MBEDTLS_ERR_SSL_INTERNAL_ERROR }
        let session = Unmanaged<MiniMedTLSServer>.fromOpaque(p).takeUnretainedValue()
        session.sendQueue.write(Data(bytes: buf, count: Int(len)))
        return Int32(len)
    }

    private static func recvCallbackBody(
        _ p: UnsafeMutableRawPointer?,
        _ buf: UnsafeMutablePointer<UInt8>?,
        _ len: Int
    ) -> Int32 {
        guard let p, let buf, len > 0 else { return MBEDTLS_ERR_SSL_INTERNAL_ERROR }
        let session = Unmanaged<MiniMedTLSServer>.fromOpaque(p).takeUnretainedValue()
        let data = session.recvQueue.read(count: Int(len))
        guard !data.isEmpty else { return MBEDTLS_ERR_SSL_WANT_READ }
        data.withUnsafeBytes { src in
            buf.update(from: src.bindMemory(to: UInt8.self).baseAddress!, count: data.count)
        }
        return Int32(data.count)
    }

    private func errorString(_ rc: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        mbedtls_strerror(rc, &buf, buf.count)
        return String(cString: buf)
    }
}
