import CoreBluetooth
import Foundation

/// GATT profile constants for the *server* (pump) side of the MiniMed Flex.
///
/// Derived from `minimed-flex-reversing/docs/1.GATT profile.md`,
/// `minimed-flex-reversing/swift/Sources/MiniMedFlex/GATTProfile.swift` and
/// `docs/2.After discovering.md`. This is the pump-simulator view: we *host* these
/// services/characteristics and respond to the phone's writes.
///
/// UUID bases:
/// - Primary Medtronic base: `-0000-1000-0000-009132591325`
/// - Secondary / MTS base:   `-0000-2000-0000-009132591325`
/// - Bluetooth SIG base:     `-0000-1000-8000-00805F9B34FB`
public enum MiniMedGATT {
    // MARK: - UUID bases

    public static let primarySuffix = "-0000-1000-0000-009132591325"
    public static let mtsSuffix = "-0000-2000-0000-009132591325"
    public static let sigSuffix = "-0000-1000-8000-00805F9B34FB"

    /// Medtronic manufacturer company id `0x1010` (little-endian bytes `10 10`).
    public static let medtronicCompanyID: UInt16 = 0x1010

    /// The service UUID the phone's scanner keys on (`00000100`, InsulinDeliveryService).
    public static let insulinDeliveryService = CBUUID(string: "00000100\(primarySuffix)")

    // MARK: - Service A: InsulinDeliveryService (IDD)

    public static let iddService = CBUUID(string: "00000100\(primarySuffix)")

    public static let iddChar0101 = CBUUID(string: "00000101\(primarySuffix)") // encrypted
    public static let iddChar0102 = CBUUID(string: "00000102\(primarySuffix)") // encrypted
    public static let iddChar0103 = CBUUID(string: "00000103\(primarySuffix)") // encrypted
    public static let iddChar0108 = CBUUID(string: "00000108\(primarySuffix)") // encrypted
    public static let iddChar0110 = CBUUID(string: "00000110\(primarySuffix)") // encrypted
    public static let iddChar0112 = CBUUID(string: "00000112\(primarySuffix)") // encrypted
    public static let iddChar0113 = CBUUID(string: "00000113\(primarySuffix)") // encrypted
    public static let iddChar0114 = CBUUID(string: "00000114\(primarySuffix)") // encrypted

    /// Record Access Control Point (SIG 0x2A52) — TLS-encrypted.
    public static let racp = CBUUID(string: "00002A52\(sigSuffix)")

    // MARK: - Service B: DeviceTimeService

    public static let deviceTimeService = CBUUID(string: "00001300\(primarySuffix)")
    public static let deviceTimeChar1 = CBUUID(string: "00001302\(primarySuffix)") // encrypted
    public static let deviceTimeChar2 = CBUUID(string: "00001303\(primarySuffix)") // encrypted

    // MARK: - Services C/D/E: Message Transfer Services (MTS)

    public static let realTimeMTS = CBUUID(string: "00007100\(mtsSuffix)") // MTS0
    public static let nonRealTimeMTS = CBUUID(string: "00007110\(mtsSuffix)") // MTS1
    public static let connectionMgmMTS = CBUUID(string: "00009100\(primarySuffix)") // MTS2

    public enum RealTimeMTS {
        public static let controlPoint = CBUUID(string: "00007101\(mtsSuffix)") // send (encrypted)
        public static let data = CBUUID(string: "00007102\(mtsSuffix)") // recv (encrypted)
        public static let notification = CBUUID(string: "00007103\(mtsSuffix)") // doorbell
        public static let configuration = CBUUID(string: "00007104\(mtsSuffix)") // read
    }

    public enum NonRealTimeMTS {
        public static let controlPoint = CBUUID(string: "00007111\(mtsSuffix)")
        public static let data = CBUUID(string: "00007112\(mtsSuffix)")
        public static let notification = CBUUID(string: "00007113\(mtsSuffix)")
        public static let configuration = CBUUID(string: "00007114\(mtsSuffix)")
    }

    public enum ConnectionMgmMTS {
        public static let controlPoint = CBUUID(string: "00009101\(primarySuffix)")
        public static let data = CBUUID(string: "00009102\(primarySuffix)")
        public static let notification = CBUUID(string: "00009103\(primarySuffix)")
        public static let configuration = CBUUID(string: "00009104\(primarySuffix)")
    }

    // MARK: - Encrypted set

    /// Characteristics that ride the TLS record layer once the secure link is up
    /// (`docs/10 §6`, `docs/12 §8`, reference GATTProfile).
    public static let encryptedCharUUIDs: [CBUUID] = [
        RealTimeMTS.controlPoint, RealTimeMTS.data,
        iddChar0101, iddChar0102, iddChar0103, iddChar0108,
        iddChar0110, iddChar0112, iddChar0113, iddChar0114,
        deviceTimeChar1, deviceTimeChar2,
        racp,
    ]

    public static func isEncrypted(_ uuid: CBUUID) -> Bool {
        encryptedCharUUIDs.contains(uuid)
    }
}
