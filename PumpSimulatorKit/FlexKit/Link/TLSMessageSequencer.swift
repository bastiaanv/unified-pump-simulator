import Foundation

/// Shared per-secure-link ordered-delivery helper —
/// `TlsMessageSequencerImpl` (`docs/12`). Gives every TLS-encrypted record on the
/// encrypted characteristics a 1-byte transmit/receive sequence number, wrapping at
/// 0xff.
///
/// In Tier A (transparent link) this is applied to the CCMP payload directly.
final class TLSMessageSequencer {
    private var txSeq: UInt8 = 0
    private var rxSeq: UInt8 = 0
    private let lock = NSLock()

    init() {}

    /// Prefix the transmit counter, then bump it (wrap at 0xff).
    func prefixWithSequenceNumber(_ payload: [UInt8]) -> [UInt8] {
        lock.lock()
        let byte = txSeq
        txSeq = (txSeq >= 0xFF) ? 0 : txSeq &+ 1
        lock.unlock()
        return [byte] + payload
    }

    /// Consume one ordered inbound record; advance the receive counter (wrap at 0xff).
    func releaseCryptoLock() {
        lock.lock()
        rxSeq = (rxSeq >= 0xFF) ? 0 : rxSeq &+ 1
        lock.unlock()
    }

    /// Zero both counters (per-new-TLS-session).
    func reset() {
        lock.lock()
        txSeq = 0
        rxSeq = 0
        lock.unlock()
    }

    var currentTxSeq: UInt8 {
        lock.lock()
        let v = txSeq
        lock.unlock()
        return v
    }
}
