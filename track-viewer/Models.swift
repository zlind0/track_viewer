import Foundation
import CoreLocation

// MARK: - View Mode

enum ViewMode: Equatable {
    case singleDay
    case multiDay
    case singleDayFromMulti  // Drill-down from multi-day view
}

// MARK: - Track Point

struct TrackPoint: Identifiable, Sendable {
    let id: Int64
    let timestamp: TimeInterval
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speed: Double
    let heading: Double
    let accuracy: Double
    let distance: Double        // distance from previous point (m)
    let localDate: String       // YYYY-MM-DD in local timezone
    let timezoneOffsetHours: Int

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var localTimeString: String {
        let tz = TimeZone(secondsFromGMT: timezoneOffsetHours * 3600) ?? .current
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = tz
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

// MARK: - Daily Summary

struct DailySummary: Identifiable, Sendable {
    let date: String            // YYYY-MM-DD
    let totalDistanceMeters: Double
    let pointCount: Int

    var id: String { date }

    var totalDistanceKm: Double { totalDistanceMeters / 1000.0 }

    /// Non-linear intensity: sqrt gives more variation at low distances (0–30 km range).
    var colorIntensity: Double {
        let km = totalDistanceKm
        guard km > 0 else { return 0 }
        return sqrt(min(km, 300.0) / 300.0)
    }

    var parsedDate: Date? { DateFormatter.utcDate.date(from: date) }
}

// MARK: - File Cache Record

struct FileRecord: Sendable {
    let md5: String
    let filePath: String
    let importedAt: Date
    let pointCount: Int
}

// MARK: - Hover Info

struct TrackHoverInfo {
    let point: TrackPoint
    let screenPosition: CGPoint
}

struct DayHoverInfo {
    let dateStr: String
    let distanceKm: Double
    let screenPosition: CGPoint
}

// MARK: - Date Formatter Helpers

extension DateFormatter {
    /// Parses/formats "yyyy-MM-dd" using UTC so there's no timezone ambiguity.
    static let utcDate: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        return df
    }()
}

// MARK: - Calendar Helpers

extension Calendar {
    static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()
}
