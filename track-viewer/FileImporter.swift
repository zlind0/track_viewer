import Foundation
import CoreLocation
import CryptoKit

// MARK: - FileImporter

enum FileImporter {

    // MARK: MD5

    /// Computes the MD5 hex string of a file by streaming it in 256 KB chunks.
    static func md5(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = Insecure.MD5()
        let chunkSize = 256 * 1024
        while true {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Raw Point

    /// Raw GPS point as parsed from file, before coordinate conversion or timezone resolution.
    typealias RawPoint = (timestamp: Double, lat: Double, lon: Double,
                          alt: Double, speed: Double, heading: Double,
                          accuracy: Double, distanceM: Double)

    // MARK: Parallel Conversion

    /// Converts and timezone-resolves a batch of raw GPS points in parallel.
    ///
    /// The batch is divided into N chunks where N = CPU core count clamped to [4, 8].
    /// Each chunk runs as an independent Swift concurrency task on the global thread pool,
    /// achieving true multi-core parallelism for the CPU-bound polygon and trig work.
    static func parallelConvert(
        _ raw: [RawPoint]
    ) async -> [(timestamp: Double, lat: Double, lon: Double,
                 alt: Double, speed: Double, heading: Double,
                 accuracy: Double, distanceM: Double,
                 localDate: String, tzOffsetHours: Int)] {
        guard !raw.isEmpty else { return [] }
        let workers   = max(4, min(8, ProcessInfo.processInfo.processorCount))
        let count     = raw.count
        let chunkSize = max(1, (count + workers - 1) / workers)
        let numChunks = (count + chunkSize - 1) / chunkSize

        typealias DBRow = (timestamp: Double, lat: Double, lon: Double,
                           alt: Double, speed: Double, heading: Double,
                           accuracy: Double, distanceM: Double,
                           localDate: String, tzOffsetHours: Int)

        return await withTaskGroup(of: (Int, [DBRow]).self) { group in
            for i in 0..<numChunks {
                let start = i * chunkSize
                let end   = min(start + chunkSize, count)
                let slice = Array(raw[start..<end])
                group.addTask {
                    // One DateFormatter per task — never shared across threads.
                    let fmt = DateFormatter()
                    fmt.dateFormat = "yyyy-MM-dd"
                    fmt.locale     = Locale(identifier: "en_US_POSIX")
                    var lastTzOffset = Int.min
                    let rows: [DBRow] = slice.map { p in
                        let cvt = CoordinateConverter.gcj02ToWgs84(
                            CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
                        )
                        let tzOffset = TimezoneUtils.timezoneOffset(longitude: p.lon)
                        if tzOffset != lastTzOffset {
                            fmt.timeZone = TimeZone(secondsFromGMT: tzOffset * 3600) ?? .current
                            lastTzOffset = tzOffset
                        }
                        let dateStr = fmt.string(from: Date(timeIntervalSince1970: p.timestamp))
                        return (p.timestamp, cvt.latitude, cvt.longitude,
                                p.alt, p.speed, p.heading, p.accuracy, p.distanceM,
                                dateStr, tzOffset)
                    }
                    return (i, rows)
                }
            }
            var parts = [(Int, [DBRow])]()
            for await pair in group { parts.append(pair) }
            return parts.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
        }
    }

    // MARK: CSV

    /// Streams a CSV file line-by-line and inserts rows into the database.
    /// Returns the total number of points inserted.
    static func importCSV(
        url: URL,
        fileMD5: String,
        database: DatabaseManager,
        onProgress: @Sendable @escaping (Double, String) async -> Void
    ) async throws -> Int {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 1
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var bytesRead: Int = 0
        var totalInserted: Int = 0
        var isFirstLine = true
        var remainder = ""
        let chunkSize = 512 * 1024   // 512 KB read at a time
        var batch: [RawPoint] = []
        batch.reserveCapacity(10_000)

        while true {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty { break }
            bytesRead += data.count

            guard let chunk = String(data: data, encoding: .utf8) else { continue }
            let lines = (remainder + chunk).components(separatedBy: "\n")
            remainder = lines.last ?? ""

            for line in lines.dropLast() {
                if isFirstLine { isFirstLine = false; continue }   // skip header
                let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count >= 11 else { continue }

                guard let ts  = Double(fields[0].trimmingCharacters(in: .whitespaces)),
                      let lon = Double(fields[2].trimmingCharacters(in: .whitespaces)),
                      let lat = Double(fields[3].trimmingCharacters(in: .whitespaces)) else { continue }

                let heading  = Double(fields[4].trimmingCharacters(in: .whitespaces)) ?? 0
                let accuracy = Double(fields[5].trimmingCharacters(in: .whitespaces)) ?? 0
                let speed    = Double(fields[6].trimmingCharacters(in: .whitespaces)) ?? -1
                let distM    = Double(fields[7].trimmingCharacters(in: .whitespaces)) ?? 0
                let alt      = Double(fields[10].trimmingCharacters(in: .whitespaces)) ?? 0

                batch.append((ts, lat, lon, alt, speed, heading, accuracy, distM))

                if batch.count >= 10_000 {
                    let raw = batch
                    batch.removeAll(keepingCapacity: true)
                    let converted = await parallelConvert(raw)
                    try await database.insertTrackPoints(fileMD5: fileMD5, batch: converted) { _ in }
                    totalInserted += converted.count
                    let pct = Double(bytesRead) / Double(fileSize)
                    await onProgress(pct, "已导入 \(totalInserted) 个轨迹点…")
                }
            }
        }

        // Process last remainder line
        if !remainder.isEmpty {
            let fields = remainder.split(separator: ",", omittingEmptySubsequences: false)
            if fields.count >= 11,
               let ts  = Double(fields[0].trimmingCharacters(in: .whitespaces)),
               let lon = Double(fields[2].trimmingCharacters(in: .whitespaces)),
               let lat = Double(fields[3].trimmingCharacters(in: .whitespaces)) {
                let heading  = Double(fields[4].trimmingCharacters(in: .whitespaces)) ?? 0
                let accuracy = Double(fields[5].trimmingCharacters(in: .whitespaces)) ?? 0
                let speed    = Double(fields[6].trimmingCharacters(in: .whitespaces)) ?? -1
                let distM    = Double(fields[7].trimmingCharacters(in: .whitespaces)) ?? 0
                let alt      = Double(fields[10].trimmingCharacters(in: .whitespaces)) ?? 0
                batch.append((ts, lat, lon, alt, speed, heading, accuracy, distM))
            }
        }

        if !batch.isEmpty {
            let converted = await parallelConvert(batch)
            try await database.insertTrackPoints(fileMD5: fileMD5, batch: converted) { _ in }
            totalInserted += converted.count
        }

        return totalInserted
    }

    // MARK: GPX

    /// Streams a GPX file using SAX-style XMLParser.
    static func importGPX(
        url: URL,
        fileMD5: String,
        database: DatabaseManager,
        onProgress: @Sendable @escaping (Double, String) async -> Void
    ) async throws -> Int {
        let parser = GPXParser(url: url, fileMD5: fileMD5, database: database, onProgress: onProgress)
        return try await parser.parse()
    }
}

// MARK: - GPXParser

private final class GPXParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private let url: URL
    private let fileMD5: String
    private let database: DatabaseManager
    private let onProgress: @Sendable (Double, String) async -> Void

    private var currentElement = ""
    private var currentLat: Double = 0
    private var currentLon: Double = 0
    private var currentEle: Double = 0
    private var currentTime: TimeInterval = 0
    private var currentSpeed: Double = -1
    private var currentText = ""
    private var inTrkpt = false

    private var batch: [FileImporter.RawPoint] = []
    private var totalInserted = 0
    private var parseError: Error?

    // GPX date parser (ISO 8601 UTC)
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // We use a continuation to bridge the sync XMLParser into async.
    private var continuation: CheckedContinuation<Int, Error>?

    init(url: URL, fileMD5: String, database: DatabaseManager,
         onProgress: @Sendable @escaping (Double, String) async -> Void) {
        self.url = url
        self.fileMD5 = fileMD5
        self.database = database
        self.onProgress = onProgress
    }

    func parse() async throws -> Int {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let parser = XMLParser(contentsOf: url)
            parser?.delegate = self
            // Run on a background thread so we don't block the main actor
            Task.detached {
                if !(parser?.parse() ?? false) {
                    cont.resume(throwing: self.parseError ?? DatabaseError.openFailed("GPX parse failed"))
                }
            }
        }
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "trkpt" {
            inTrkpt = true
            currentLat   = Double(attributeDict["lat"] ?? "0") ?? 0
            currentLon   = Double(attributeDict["lon"] ?? "0") ?? 0
            currentEle   = 0
            currentTime  = 0
            currentSpeed = -1
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard inTrkpt else { return }
        switch elementName {
        case "ele":
            currentEle = Double(currentText.trimmingCharacters(in: .whitespaces)) ?? 0
        case "time":
            if let date = isoFormatter.date(from: currentText.trimmingCharacters(in: .whitespaces)) {
                currentTime = date.timeIntervalSince1970
            }
        case "speed":
            currentSpeed = Double(currentText.trimmingCharacters(in: .whitespaces)) ?? -1
        case "trkpt":
            inTrkpt = false
            guard currentTime > 0 else { return }
            batch.append((currentTime, currentLat, currentLon,
                          currentEle, currentSpeed, 0, 0, 0))
            if batch.count >= 10_000 {
                flushBatch()
            }
        default: break
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        flushBatch()
        continuation?.resume(returning: totalInserted)
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
        continuation?.resume(throwing: parseError)
    }

    private func flushBatch() {
        guard !batch.isEmpty else { return }
        let raw = batch
        batch.removeAll(keepingCapacity: true)
        let count = raw.count
        // Synchronous call into the actor — acceptable here because we're on a background thread.
        let sema = DispatchSemaphore(value: 0)
        Task {
            let converted = await FileImporter.parallelConvert(raw)
            try? await database.insertTrackPoints(fileMD5: fileMD5, batch: converted) { _ in }
            totalInserted += count
            await onProgress(0, "已导入 \(totalInserted) 个轨迹点…")
            sema.signal()
        }
        sema.wait()
    }
}
