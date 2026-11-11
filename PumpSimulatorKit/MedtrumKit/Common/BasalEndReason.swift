/// Why a basal segment ended, as a basal record carries it (AndroidAPS `BasalEndReason.kt`). The patch writes SUCCESS
/// for a temp basal that was cancelled as well as one that ran out; only a halt writes anything else.
enum BasalEndReason: UInt8, Codable {
    case SUCCESS
    case SUSPEND_LOW_GLUCOSE
    case SUSPEND_PREDICT_LOW_GLUCOSE
    case SUSPEND_AUTO
    case SUSPEND_MORE_THAN_MAX_PER_HOUR
    case SUSPEND_MORE_THAN_MAX_PER_DAY
    case SUSPEND_MANUAL
    case STOP_OCCLUSION
    case STOP_EXPIRED
    case STOP_EMPTY
    case STOP_PATCH_FAULT
    case STOP_PATCH_FAULT2
    case STOP_BASE_FAULT
    case STOP_PATCH_BATTERY_EMPTY
    case STOP_MAG_SENSOR_NO_CALIBRATION
    case STOP
    case STOP_LOW_BATTERY
    case STOP_AUTO_EXIT
    case STOP_CANCEL
    case STOP_LOW_SUPER_CAPACITOR
    case STOP_DISCARD
    case PAUSE_INTERRUPT
    case AUTO_MODE_EXIT
    case AUTO_MODE_EXIT_MIN_DELIVERY_TOO_LONG
    case AUTO_MODE_EXIT_NO_GLUCOSE_3_HOUR
    case AUTO_MODE_EXIT_MAX_DELIVERY_TOO_LONG
}
