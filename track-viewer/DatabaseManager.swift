import Foundation
import SQLite3

// MARK: - SQLITE_TRANSIENT workaround
// In Swift, SQLITE_TRANSIENT is a C macro and is not exported.
// We define it ourselves as a C-convention function pointer with value -1.
private typealias SQLiteDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void
private let SQLITE_TRANSIENT = unsafeBitCast(Int(-1), to: SQLiteDestructor.self)

// MARK: - Errors

enum DatabaseError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let s):   return "Cannot open database: \(s)"
        case .prepareFailed(let s): return "Cannot prepare statement: \(s)"
        case .stepFailed(let s):  return "Statement step failed: \(s)"
        }
    }
}

// MARK: - DatabaseManager

actor DatabaseManager {

    private var db: OpaquePointer?

    // MARK: Init

    init() throws {
        let dir = try Self.appSupportDir()
        let path = dir.appendingPathComponent("tracks.db").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw DatabaseError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        try configure()
        try createSchema()
    }

    deinit { sqlite3_close(db) }

    // MARK: Configuration

    private func configure() throws {
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("PRAGMA cache_size=-32000")   // 32 MB
        exec("PRAGMA temp_store=MEMORY")
    }

    // MARK: Schema

    private func createSchema() throws {
        exec("""
        CREATE TABLE IF NOT EXISTS file_cache (
            md5          TEXT PRIMARY KEY,
            file_path    TEXT NOT NULL,
            imported_at  REAL NOT NULL,
            point_count  INTEGER NOT NULL DEFAULT 0
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS track_points (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            file_md5         TEXT NOT NULL,
            timestamp        REAL NOT NULL,
            latitude         REAL NOT NULL,
            longitude        REAL NOT NULL,
            altitude         REAL NOT NULL DEFAULT 0,
            speed            REAL NOT NULL DEFAULT -1,
            heading          REAL NOT NULL DEFAULT 0,
            accuracy         REAL NOT NULL DEFAULT 0,
            distance_m       REAL NOT NULL DEFAULT 0,
            local_date       TEXT NOT NULL,
            tz_offset_hours  INTEGER NOT NULL DEFAULT 0
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_tp_file_date  ON track_points(file_md5, local_date);")
        exec("CREATE INDEX IF NOT EXISTS idx_tp_file_ts    ON track_points(file_md5, timestamp);")
        exec("""
        CREATE TABLE IF NOT EXISTS daily_summaries (
            file_md5         TEXT NOT NULL,
            local_date       TEXT NOT NULL,
            total_distance_m REAL NOT NULL DEFAULT 0,
            point_count      INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (file_md5, local_date)
        );
        """)
    }

    // MARK: File Cache

    func fileCacheExists(md5: String) -> Bool {
        let sql = "SELECT 1 FROM file_cache WHERE md5 = ? LIMIT 1"
        guard let stmt = prepare(sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, md5, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func upsertFileCache(md5: String, filePath: String, pointCount: Int) {
        let sql = """
        INSERT INTO file_cache (md5, file_path, imported_at, point_count)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(md5) DO UPDATE SET
            file_path   = excluded.file_path,
            imported_at = excluded.imported_at,
            point_count = excluded.point_count
        """
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, md5, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, filePath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        sqlite3_bind_int(stmt, 4, Int32(pointCount))
        sqlite3_step(stmt)
    }

    /// Keeps only the 5 most-recently-imported files; removes the rest.
    func trimOldFiles() {
        // Collect MD5s to remove
        let selectSQL = """
        SELECT md5 FROM file_cache
        ORDER BY imported_at DESC
        LIMIT -1 OFFSET 5
        """
        guard let stmt = prepare(selectSQL) else { return }
        var toDelete: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            toDelete.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        sqlite3_finalize(stmt)

        for md5 in toDelete {
            exec("DELETE FROM track_points WHERE file_md5 = '\(md5)'")
            exec("DELETE FROM daily_summaries WHERE file_md5 = '\(md5)'")
            exec("DELETE FROM file_cache WHERE md5 = '\(md5)'")
        }
    }

    // MARK: Bulk Insert

    /// Inserts a batch of raw rows. Each tuple:
    /// (timestamp, lat, lon, alt, speed, heading, accuracy, distance_m, local_date, tz_offset_hours)
    func insertTrackPoints(
        fileMD5: String,
        batch: [(timestamp: Double, lat: Double, lon: Double,
                 alt: Double, speed: Double, heading: Double,
                 accuracy: Double, distanceM: Double,
                 localDate: String, tzOffsetHours: Int)],
        onProgress: @Sendable (Int) -> Void
    ) throws {
        exec("BEGIN TRANSACTION")
        let sql = """
        INSERT INTO track_points
            (file_md5, timestamp, latitude, longitude, altitude,
             speed, heading, accuracy, distance_m, local_date, tz_offset_hours)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        """
        guard let stmt = prepare(sql) else {
            exec("ROLLBACK")
            throw DatabaseError.prepareFailed("insertTrackPoints")
        }
        defer { sqlite3_finalize(stmt) }

        let batchSize = 5_000
        for (idx, row) in batch.enumerated() {
            sqlite3_bind_text(stmt, 1, fileMD5, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, row.timestamp)
            sqlite3_bind_double(stmt, 3, row.lat)
            sqlite3_bind_double(stmt, 4, row.lon)
            sqlite3_bind_double(stmt, 5, row.alt)
            sqlite3_bind_double(stmt, 6, row.speed)
            sqlite3_bind_double(stmt, 7, row.heading)
            sqlite3_bind_double(stmt, 8, row.accuracy)
            sqlite3_bind_double(stmt, 9, row.distanceM)
            sqlite3_bind_text(stmt, 10, row.localDate, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 11, Int32(row.tzOffsetHours))
            if sqlite3_step(stmt) != SQLITE_DONE {
                exec("ROLLBACK")
                throw DatabaseError.stepFailed("insertTrackPoints row \(idx)")
            }
            sqlite3_reset(stmt)

            if (idx + 1) % batchSize == 0 {
                exec("COMMIT")
                onProgress(idx + 1)
                exec("BEGIN TRANSACTION")
            }
        }
        exec("COMMIT")
    }

    // MARK: Daily Summaries

    func computeAndStoreDailySummaries(fileMD5: String) {
        exec("DELETE FROM daily_summaries WHERE file_md5 = '\(fileMD5)'")
        exec("""
        INSERT INTO daily_summaries (file_md5, local_date, total_distance_m, point_count)
        SELECT
            file_md5,
            local_date,
            SUM(CASE WHEN distance_m > 0 AND distance_m < 50000 THEN distance_m ELSE 0 END),
            COUNT(*)
        FROM track_points
        WHERE file_md5 = '\(fileMD5)'
        GROUP BY file_md5, local_date
        """)
    }

    // MARK: Queries

    func getDailySummaries(fileMD5: String) -> [DailySummary] {
        let sql = """
        SELECT local_date, total_distance_m, point_count
        FROM daily_summaries
        WHERE file_md5 = ?
        ORDER BY local_date DESC
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, fileMD5, -1, SQLITE_TRANSIENT)

        var results: [DailySummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let date    = String(cString: sqlite3_column_text(stmt, 0))
            let distM   = sqlite3_column_double(stmt, 1)
            let count   = Int(sqlite3_column_int(stmt, 2))
            results.append(DailySummary(date: date, totalDistanceMeters: distM, pointCount: count))
        }
        return results
    }

    func getTrackPoints(fileMD5: String, date: String) -> [TrackPoint] {
        let sql = """
        SELECT id, timestamp, latitude, longitude, altitude,
               speed, heading, accuracy, distance_m, local_date, tz_offset_hours
        FROM track_points
        WHERE file_md5 = ? AND local_date = ?
        ORDER BY timestamp ASC
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, fileMD5, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, date, -1, SQLITE_TRANSIENT)

        var results: [TrackPoint] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(TrackPoint(
                id:               sqlite3_column_int64(stmt, 0),
                timestamp:        sqlite3_column_double(stmt, 1),
                latitude:         sqlite3_column_double(stmt, 2),
                longitude:        sqlite3_column_double(stmt, 3),
                altitude:         sqlite3_column_double(stmt, 4),
                speed:            sqlite3_column_double(stmt, 5),
                heading:          sqlite3_column_double(stmt, 6),
                accuracy:         sqlite3_column_double(stmt, 7),
                distance:         sqlite3_column_double(stmt, 8),
                localDate:        String(cString: sqlite3_column_text(stmt, 9)),
                timezoneOffsetHours: Int(sqlite3_column_int(stmt, 10))
            ))
        }
        return results
    }

    func getTrackPointsForDates(fileMD5: String, dates: [String]) -> [String: [TrackPoint]] {
        guard !dates.isEmpty else { return [:] }
        let placeholders = dates.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT id, timestamp, latitude, longitude, altitude,
               speed, heading, accuracy, distance_m, local_date, tz_offset_hours
        FROM track_points
        WHERE file_md5 = ? AND local_date IN (\(placeholders))
        ORDER BY local_date ASC, timestamp ASC
        """
        guard let stmt = prepare(sql) else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, fileMD5, -1, SQLITE_TRANSIENT)
        for (i, d) in dates.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 2), d, -1, SQLITE_TRANSIENT)
        }

        var result: [String: [TrackPoint]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tp = TrackPoint(
                id:               sqlite3_column_int64(stmt, 0),
                timestamp:        sqlite3_column_double(stmt, 1),
                latitude:         sqlite3_column_double(stmt, 2),
                longitude:        sqlite3_column_double(stmt, 3),
                altitude:         sqlite3_column_double(stmt, 4),
                speed:            sqlite3_column_double(stmt, 5),
                heading:          sqlite3_column_double(stmt, 6),
                accuracy:         sqlite3_column_double(stmt, 7),
                distance:         sqlite3_column_double(stmt, 8),
                localDate:        String(cString: sqlite3_column_text(stmt, 9)),
                timezoneOffsetHours: Int(sqlite3_column_int(stmt, 10))
            )
            result[tp.localDate, default: []].append(tp)
        }
        return result
    }

    // MARK: Helpers

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        return stmt
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func appSupportDir() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("TrackViewer", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
