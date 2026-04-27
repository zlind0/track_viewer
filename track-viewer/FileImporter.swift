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
        var batch: [(timestamp: Double, lat: Double, lon: Double,
                     alt: Double, speed: Double, heading: Double,
                     accuracy: Double, distanceM: Double,
                     localDate: String, tzOffsetHours: Int)] = []
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

                let tzOffset = TimezoneUtils.timezoneOffset(longitude: lon)
                let dateStr  = TimezoneUtils.localDateString(timestamp: ts, offsetHours: tzOffset)
                let cvt      = CoordinateConverter.gcj02ToWgs84(CLLocationCoordinate2D(latitude: lat, longitude: lon))

                batch.append((ts, cvt.latitude, cvt.longitude, alt, speed, heading, accuracy, distM, dateStr, tzOffset))

                if batch.count >= 10_000 {
                    let captured = batch
                    try await database.insertTrackPoints(fileMD5: fileMD5, batch: captured) { _ in }
                    totalInserted += captured.count
                    batch.removeAll(keepingCapacity: true)
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
                let tzOffset = TimezoneUtils.timezoneOffset(longitude: lon)
                let dateStr  = TimezoneUtils.localDateString(timestamp: ts, offsetHours: tzOffset)
                let heading  = Double(fields[4].trimmingCharacters(in: .whitespaces)) ?? 0
                let accuracy = Double(fields[5].trimmingCharacters(in: .whitespaces)) ?? 0
                let speed    = Double(fields[6].trimmingCharacters(in: .whitespaces)) ?? -1
                let distM    = Double(fields[7].trimmingCharacters(in: .whitespaces)) ?? 0
                let alt      = Double(fields[10].trimmingCharacters(in: .whitespaces)) ?? 0
                let cvt      = CoordinateConverter.gcj02ToWgs84(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                batch.append((ts, cvt.latitude, cvt.longitude, alt, speed, heading, accuracy, distM, dateStr, tzOffset))
            }
        }

        if !batch.isEmpty {
            let captured = batch
            try await database.insertTrackPoints(fileMD5: fileMD5, batch: captured) { _ in }
            totalInserted += captured.count
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

    private var batch: [(timestamp: Double, lat: Double, lon: Double,
                         alt: Double, speed: Double, heading: Double,
                         accuracy: Double, distanceM: Double,
                         localDate: String, tzOffsetHours: Int)] = []
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
            let tzOffset = TimezoneUtils.timezoneOffset(longitude: currentLon)
            let dateStr  = TimezoneUtils.localDateString(timestamp: currentTime, offsetHours: tzOffset)
            let cvt      = CoordinateConverter.gcj02ToWgs84(CLLocationCoordinate2D(latitude: currentLat, longitude: currentLon))
            batch.append((currentTime, cvt.latitude, cvt.longitude,
                          currentEle, currentSpeed, 0, 0, 0,
                          dateStr, tzOffset))
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
        let captured = batch
        batch.removeAll(keepingCapacity: true)
        let count = captured.count
        // Synchronous call into the actor — acceptable here because we're on a background thread.
        let sema = DispatchSemaphore(value: 0)
        Task {
            try? await database.insertTrackPoints(fileMD5: fileMD5, batch: captured) { _ in }
            totalInserted += count
            await onProgress(0, "已导入 \(totalInserted) 个轨迹点…")
            sema.signal()
        }
        sema.wait()
    }
}
