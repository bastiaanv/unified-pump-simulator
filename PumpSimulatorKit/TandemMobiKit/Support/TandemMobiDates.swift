import Foundation

/// Tandem pump epoch (seconds since 2008-01-01). Port of
/// TandemKit/Sources/TandemCore/Common/Dates.swift.
enum TandemMobiDates {
    static let january12008UnixEpoch: TimeInterval = 1_199_145_600

    static func currentTimeSinceJan12008() -> UInt32 {
        let now = Date().timeIntervalSince1970
        let tsr = now - january12008UnixEpoch
        return UInt32(tsr)
    }

    static func toUnixEpochSeconds(_ jan12008Seconds: TimeInterval) -> TimeInterval {
        jan12008Seconds + january12008UnixEpoch - TimeInterval(TimeZone.current.secondsFromGMT())
    }

    static func fromDateToJan12008EpochSeconds(_ date: Date) -> TimeInterval {
        date.timeIntervalSince1970 - january12008UnixEpoch + TimeInterval(TimeZone.current.secondsFromGMT())
    }
}
