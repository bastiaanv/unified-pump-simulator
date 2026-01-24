import Foundation

enum BolusSpeed: UInt8 {
    case speed12 = 0
    case speed30 = 1
    case speed60 = 2

    func getDuration(amount: UInt16) -> TimeInterval {
        let actualAmount = Double(amount) / 100

        switch self {
        case .speed12:
            return TimeInterval(seconds: actualAmount * 12)
        case .speed30:
            return TimeInterval(seconds: actualAmount * 30)
        case .speed60:
            return TimeInterval(seconds: actualAmount * 60)
        }
    }
}
