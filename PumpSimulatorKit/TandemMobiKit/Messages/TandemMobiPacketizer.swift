import CoreBluetooth
import Foundation

/// One ATT write (one packet) carrying a fragment of a Tron message.
struct TandemMobiPacket {
    let packetsRemaining: UInt8
    let txId: UInt8
    let chunk: Data

    /// On-wire bytes: [packetsRemaining][txId][chunk...].
    func build() -> Data {
        var data = Data()
        data.append(packetsRemaining)
        data.append(txId)
        data.append(chunk)
        return data
    }
}

/// Send-side packetizer (PUMP → CENTRAL) and receive-side defragmenter
/// (CENTRAL → PUMP). Byte-exact adaptation of TandemKit's `Packetizer.swift`.
enum TandemMobiPacketizer {
    private static let defaultChunkSize = 18

    private static func chunked(_ data: Data, into size: Int) -> [Data] {
        var result: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + size, data.count)
            result.append(data.subdata(in: offset ..< end))
            offset = end
        }
        return result
    }

    /// Builds the sequence of ATT packets that carry `response` to the central,
    /// appending a 24-byte HMAC signature when the response is signed.
    static func packetize(
        response: TandemMobiResponse,
        authKey: Data?,
        txId: UInt8,
        timeSinceReset: UInt32?
    ) -> [TandemMobiPacket] {
        let chunkSize = defaultChunkSize
        let payloadLength = response.cargo.count + (response.signed ? 24 : 0)
        guard payloadLength < 256 else { return [] }

        var packet = Data()
        packet.append(response.opCode)
        packet.append(txId)
        packet.append(UInt8(payloadLength))
        packet.append(response.cargo)

        if response.signed {
            guard let authKey = authKey, let timeSinceReset = timeSinceReset else {
                return []
            }
            // Reserve the 24 signature bytes.
            packet.append(Data(repeating: 0, count: 24))
            let hmacStartIndex = packet.count - 20

            var messageData = TandemMobiBytes.firstN(packet, hmacStartIndex)
            let tsrBytes = TandemMobiBytes.u32(timeSinceReset)
            let tsrRange = (messageData.count - 4) ..< messageData.count
            messageData.replaceSubrange(tsrRange, with: tsrBytes)

            let sig = TandemMobiHmac.hmacSha1(data: messageData, key: authKey)
            packet.replaceSubrange(0 ..< hmacStartIndex, with: messageData)
            packet.replaceSubrange(hmacStartIndex ..< hmacStartIndex + sig.count, with: sig)
        }

        let crc = TandemMobiCRC16.calculate(packet)
        var packetWithCrc = packet
        packetWithCrc.append(crc)

        let chunks = chunked(packetWithCrc, into: chunkSize)
        var remaining = chunks.count - 1
        return chunks.map { chunk in
            let p = TandemMobiPacket(packetsRemaining: UInt8(remaining), txId: txId, chunk: chunk)
            remaining -= 1
            return p
        }
    }
}

/// Receive-side defragmenter. The central writes one ATT packet at a time; each
/// `didReceiveWrite` delivers one packet. We keep per-characteristic accumulation
/// state and emit a complete `(opCode, cargo, txId)` once packetsRemaining hits 0.
final class TandemMobiDefragmenter {
    private struct Stream {
        var active = false
        var opCode: UInt8 = 0
        var txId: UInt8 = 0
        var cargo = Data()
    }

    private var streams: [CBUUID: Stream] = [:]

    /// Returns a complete message when the final packet of a message arrives.
    func ingest(_ data: Data, characteristic: CBUUID) -> (opCode: UInt8, cargo: Data, txId: UInt8)? {
        guard data.count >= 1 else { return nil }

        let packetsRemaining = Int(data[0] & 0x0F)
        var stream = streams[characteristic] ?? Stream()

        if stream.active {
            // Continuation packet: [packetsRemaining][txId][cargo...]
            guard data.count >= 2 else { return nil }
            stream.cargo.append(data.subdata(in: 2 ..< data.count))
        } else {
            // First packet: [packetsRemaining][txId][opCode][txId][len][cargo...]
            guard data.count >= 5 else { return nil }
            stream.opCode = data[2]
            stream.txId = data[1]
            stream.cargo = data.subdata(in: 5 ..< data.count)
            stream.active = true
        }

        if packetsRemaining == 0 {
            let result = (stream.opCode, stream.cargo, stream.txId)
            streams[characteristic] = Stream()
            return result
        }

        streams[characteristic] = stream
        return nil
    }

    func reset() {
        streams.removeAll()
    }
}
