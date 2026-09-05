import Foundation

/// Errors thrown by the MiniMed packet decoders.
enum MiniMedError: Error {
    case protocolError(String)
    case sequence(UInt8)
    case notSupported(String)

    var localizedDescription: String {
        switch self {
        case let .protocolError(msg): return "MiniMed protocol error: \(msg)"
        case let .sequence(seq): return "MiniMed sequence error: \(seq)"
        case let .notSupported(msg): return "MiniMed not supported: \(msg)"
        }
    }
}
