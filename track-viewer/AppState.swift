import Foundation
import CoreLocation
import Observation

@Observable
@MainActor
final class AppState {

    // MARK: - File / Loading

    var isLoading      = false
    var loadingProgress: Double = 0
    var loadingMessage = ""
    var currentFileMD5: String?
    var loadError: String?

    // MARK: - View Mode

    var viewMode: ViewMode = .singleDay
    /// When viewMode == .singleDayFromMulti, restore these on "back".
    var savedMultiDayStart: Date?
    var savedMultiDayEnd:   Date?

    // MARK: - Single-Day

    var selectedDate: String?           // YYYY-MM-DD
    var currentDayPoints: [TrackPoint] = []

    // MARK: - Multi-Day

    var multiDayStart: Date?
    var multiDayEnd:   Date?
    /// Keyed by YYYY-MM-DD, each value is the smoothed + downsampled coordinates.
    var multiDayCoords: [String: [CLLocationCoordinate2D]] = [:]
    var multiDaySummaries: [DailySummary] = []

    // MARK: - Calendar / Summaries

    var dailySummaries: [DailySummary] = []
    var summaryByDate:  [String: DailySummary] = [:]

    // MARK: - Hover

    var trackHoverInfo: TrackHoverInfo?
    var dayHoverInfo:   DayHoverInfo?

    // MARK: - UI State

    var showFullCalendar       = false
    var showDateRangePicker    = false
    var mapFitRequested        = false

    // MARK: - Database

    private(set) var database: DatabaseManager?

    // MARK: - Init

    init() {
        Task { await initDatabase() }
    }

    private func initDatabase() async {
        do {
            database = try await Task.detached { try DatabaseManager() }.value
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Import

    func importFile(_ url: URL) async {
        guard let db = database else { return }
        isLoading      = true
        loadingProgress = 0
        loadingMessage  = "计算文件指纹…"
        loadError       = nil

        do {
            // Security-scoped resource access for sandboxed apps
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

            // 1. Compute MD5
            let md5 = try await Task.detached(priority: .userInitiated) {
                try FileImporter.md5(of: url)
            }.value

            // 2. Check cache
            let cached = await db.fileCacheExists(md5: md5)
            if cached {
                loadingMessage = "从缓存加载…"
                currentFileMD5 = md5
                await loadSummariesAndSelectLatest()
                isLoading = false
                return
            }

            // 3. Import file
            loadingMessage = "导入轨迹数据…"
            let ext = url.pathExtension.lowercased()
            let pointCount: Int
            if ext == "gpx" {
                pointCount = try await FileImporter.importGPX(
                    url: url, fileMD5: md5, database: db,
                    onProgress: { [weak self] pct, msg in
                        await MainActor.run {
                            self?.loadingProgress = pct
                            self?.loadingMessage  = msg
                        }
                    }
                )
            } else {
                pointCount = try await FileImporter.importCSV(
                    url: url, fileMD5: md5, database: db,
                    onProgress: { [weak self] pct, msg in
                        await MainActor.run {
                            self?.loadingProgress = pct
                            self?.loadingMessage  = msg
                        }
                    }
                )
            }

            // 4. Daily summaries
            loadingMessage = "计算每日里程…"
            await db.computeAndStoreDailySummaries(fileMD5: md5)

            // 5. Cache entry
            await db.upsertFileCache(md5: md5, filePath: url.path, pointCount: pointCount)
            await db.trimOldFiles()

            currentFileMD5 = md5
            await loadSummariesAndSelectLatest()

        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Load Summaries

    func loadSummariesAndSelectLatest() async {
        guard let db = database, let md5 = currentFileMD5 else { return }
        let summaries = await db.getDailySummaries(fileMD5: md5)
        dailySummaries = summaries
        summaryByDate  = Dictionary(uniqueKeysWithValues: summaries.map { ($0.date, $0) })

        // Default: show the most recent day with data
        if let latest = summaries.first {
            await selectDate(latest.date)
        }
    }

    // MARK: - Select Date (single-day)

    func selectDate(_ date: String) async {
        guard let db = database, let md5 = currentFileMD5 else { return }
        selectedDate = date
        viewMode = .singleDay

        let raw = await db.getTrackPoints(fileMD5: md5, date: date)
        currentDayPoints = raw
        mapFitRequested = true
    }

    // MARK: - Multi-Day Load

    func loadMultiDay(start: Date, end: Date) async {
        guard let db = database, let md5 = currentFileMD5 else { return }
        multiDayStart = start
        multiDayEnd   = end

        // Collect dates with data in range
        let cal = Calendar.utc
        var cursor = start
        var dateStrings: [String] = []
        while cursor <= end {
            let str = DateFormatter.utcDate.string(from: cursor)
            if summaryByDate[str] != nil { dateStrings.append(str) }
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }

        let raw = await db.getTrackPointsForDates(fileMD5: md5, dates: dateStrings)

        var coords: [String: [CLLocationCoordinate2D]] = [:]
        for (date, points) in raw {
            let allCoords = points.map(\.wgs84Coordinate)
            let down = CurveUtils.downsample(allCoords, maxPoints: 500)
            coords[date] = CurveUtils.catmullRomSpline(coordinates: down, pointsPerSegment: 4)
        }
        multiDayCoords    = coords
        multiDaySummaries = dateStrings.compactMap { summaryByDate[$0] }
        viewMode = .multiDay
        mapFitRequested  = true
    }

    // MARK: - Single Day from Multi (drill-down)

    func drillDownToDay(_ date: String) async {
        savedMultiDayStart = multiDayStart
        savedMultiDayEnd   = multiDayEnd
        viewMode = .singleDayFromMulti
        await selectDate(date)
    }

    func returnToMultiDay() async {
        guard let s = savedMultiDayStart, let e = savedMultiDayEnd else {
            viewMode = .multiDay
            return
        }
        await loadMultiDay(start: s, end: e)
    }

    // MARK: - Computed Helpers

    var sortedDates: [String] {
        dailySummaries.map(\.date).sorted()
    }

    /// 13-day window around `selectedDate` (6 before, current, 6 after), only data days.
    var miniCalendarDates: [String?] {
        guard let sel = selectedDate else { return Array(repeating: nil, count: 13) }
        let sorted = sortedDates
        guard let idx = sorted.firstIndex(of: sel) else { return Array(repeating: nil, count: 13) }

        var result: [String?] = Array(repeating: nil, count: 13)
        result[6] = sel

        // Fill left (6 data-days before)
        var leftIdx = idx - 1
        for slot in stride(from: 5, through: 0, by: -1) {
            if leftIdx >= 0 {
                result[slot] = sorted[leftIdx]
                leftIdx -= 1
            }
        }

        // Fill right (6 data-days after)
        var rightIdx = idx + 1
        for slot in 7...12 {
            if rightIdx < sorted.count {
                result[slot] = sorted[rightIdx]
                rightIdx += 1
            }
        }
        return result
    }
}
