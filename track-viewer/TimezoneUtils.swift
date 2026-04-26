import Foundation
import CoreLocation

enum TimezoneUtils {

    /// Estimates timezone from longitude using standard 15°-per-hour rule.
    /// Accurate for most of the world; China (UTC+8 across all longitudes) is a common exception
    /// but the longitude 120° → +8 case happens to be correct for eastern China.
    static func timezoneOffset(longitude: Double) -> Int {
        let raw = Int(round(longitude / 15.0))
        return max(-12, min(14, raw))
    }

    /// Formats a Unix timestamp as a local YYYY-MM-DD string using the given offset.
    static func localDateString(timestamp: TimeInterval, offsetHours: Int) -> String {
        let tz = TimeZone(secondsFromGMT: offsetHours * 3600) ?? .current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = tz
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
