import Foundation

/// MTS opcode byte values (`packets/01 §2`).
///
/// ⚠ These values are low-confidence — the const-pool lists `0x01…0x06` while the
/// assembly decoder uses `0x00/0x0A/0x02/0x03/0x08`. They are centralised here so a
/// live capture can adjust them without a refactor.
enum MtsOpcode {
    /// Inbound generic response (assembly decoder).
    static let genericResponse: UInt8 = 0x00
    /// Inbound short-message receive response (assembly decoder).
    static let shortReceiveResponse: UInt8 = 0x0A
    /// Outbound full transmit request (assembly decoder).
    static let transmitRequest: UInt8 = 0x02
    /// Outbound short transmit request (assembly decoder).
    static let shortTransmitRequest: UInt8 = 0x03
}

/// Generic MTS response codes (`MtsResponseCode`).
enum MtsResponseCode: UInt8 {
    case success = 0x01
    case error = 0x02
    case unknown = 0xFF
}

/// MTS framing helpers.
enum MTS {
    /// Decode an *inbound* MTS request frame (what the phone writes to a control point).
    /// Returns the raw payload bytes (the CCMP frame).
    static func decodeRequest(_ data: Data) -> Data? {
        guard let opcode = data.first else { return nil }
        switch opcode {
        case MtsOpcode.transmitRequest:
            // `02 | <payloadLen u32 LE> | <data>`
            guard data.count >= 5 else { return nil }
            let len = Int(data.miniMedUInt32(1))
            guard 5 + len <= data.count else { return nil }
            return data.subdata(in: 5 ..< (5 + len))
        case MtsOpcode.shortTransmitRequest:
            // `03 | <raw data>`
            return data.subdata(in: 1 ..< data.count)
        default:
            return nil
        }
    }

    /// Build an *outbound* generic response frame: `00 | <responseCode u8>`.
    static func encodeGenericResponse(code: MtsResponseCode) -> Data {
        Data([MtsOpcode.genericResponse, code.rawValue])
    }

    /// Build an *outbound* short-message receive response: `0A | <data>`.
    static func encodeShortReceiveResponse(_ data: Data) -> Data {
        Data([MtsOpcode.shortReceiveResponse]) + data
    }

    /// Build an *outbound* full-transmit request frame (phone pulls via receive).
    static func encodeTransmitRequest(_ data: Data) -> Data {
        Data([MtsOpcode.transmitRequest]) + UInt32(data.count).miniMedData() + data
    }

    /// The notification doorbell: `[flag:1][size:4 LE]` on the notification char.
    static func notificationDoorbell(size: UInt32) -> Data {
        Data([1]) + size.miniMedData()
    }

    /// MTS configuration (read back from `7104`): 4× uint16 LE
    /// `[field1][field2][field3][flags]` — flags bit0 = shortMessageSupported.
    static func encodeConfiguration() -> Data {
        Data([
            0x00, 0x00, // thresholds...
            0x00, 0x00,
            0x00, 0x00,
            0x01, 0x00, // flags: shortMessageSupported
        ])
    }
}
