import Foundation
import CoreLocation

enum ChinaRegion: String, Sendable {
    case mainlandChina
    case hongKong
    case macau
    case taiwan
    case outside
}

enum ChinaRegionClassifier {
    static func region(for coordinate: CLLocationCoordinate2D) -> ChinaRegion {
        Loader.shared.region(for: coordinate)
    }
}

private struct GeoBoundingBox {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    init(coordinates: [CLLocationCoordinate2D]) {
        minLatitude = coordinates.map(\ .latitude).min() ?? 0
        maxLatitude = coordinates.map(\ .latitude).max() ?? 0
        minLongitude = coordinates.map(\ .longitude).min() ?? 0
        maxLongitude = coordinates.map(\ .longitude).max() ?? 0
    }

    init(boxes: [GeoBoundingBox]) {
        minLatitude = boxes.map(\ .minLatitude).min() ?? 0
        maxLatitude = boxes.map(\ .maxLatitude).max() ?? 0
        minLongitude = boxes.map(\ .minLongitude).min() ?? 0
        maxLongitude = boxes.map(\ .maxLongitude).max() ?? 0
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude >= minLatitude &&
        coordinate.latitude <= maxLatitude &&
        coordinate.longitude >= minLongitude &&
        coordinate.longitude <= maxLongitude
    }
}

private struct GeoPolygon {
    let outerRing: [CLLocationCoordinate2D]
    let holes: [[CLLocationCoordinate2D]]
    let boundingBox: GeoBoundingBox

    init(rings: [[CLLocationCoordinate2D]]) {
        outerRing = rings.first ?? []
        holes = Array(rings.dropFirst())
        boundingBox = GeoBoundingBox(coordinates: outerRing)
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard !outerRing.isEmpty, boundingBox.contains(coordinate) else { return false }
        guard Self.pointInRing(coordinate, ring: outerRing) else { return false }
        return !holes.contains { Self.pointInRing(coordinate, ring: $0) }
    }

    private static func pointInRing(_ point: CLLocationCoordinate2D, ring: [CLLocationCoordinate2D]) -> Bool {
        guard ring.count >= 3 else { return false }

        var isInside = false
        var previous = ring[ring.count - 1]

        for current in ring {
            let intersects = ((current.latitude > point.latitude) != (previous.latitude > point.latitude)) &&
            (point.longitude < (previous.longitude - current.longitude) * (point.latitude - current.latitude) /
             ((previous.latitude - current.latitude) == 0 ? .leastNonzeroMagnitude : (previous.latitude - current.latitude)) + current.longitude)

            if intersects {
                isInside.toggle()
            }

            previous = current
        }

        return isInside
    }
}

private struct GeoMultiPolygon {
    let polygons: [GeoPolygon]
    let boundingBox: GeoBoundingBox

    init(polygons: [GeoPolygon]) {
        self.polygons = polygons
        boundingBox = GeoBoundingBox(boxes: polygons.map(\ .boundingBox))
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard boundingBox.contains(coordinate) else { return false }
        return polygons.contains { $0.contains(coordinate) }
    }
}

private struct RegionBoundary {
    let region: ChinaRegion
    let geometry: GeoMultiPolygon

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        geometry.contains(coordinate)
    }
}

private final class Loader {
    static let shared = Loader()

    private let orderedRegions: [RegionBoundary]

    private init() {
        orderedRegions = Self.loadBoundaries()
    }

    func region(for coordinate: CLLocationCoordinate2D) -> ChinaRegion {
        for boundary in orderedRegions where boundary.contains(coordinate) {
            return boundary.region
        }
        return .outside
    }

    private static func loadBoundaries() -> [RegionBoundary] {
        let definitions: [(ChinaRegion, String)] = [
            (.hongKong, "nominatim_hkg"),
            (.macau, "nominatim_mac"),
            (.taiwan, "gadm41_TWN_0"),
            (.mainlandChina, "gadm41_CHN_0")
        ]

        return definitions.compactMap { region, fileName in
            do {
                return try loadBoundary(region: region, fileName: fileName)
            } catch {
                assertionFailure("Failed to load boundary data for \(region): \(error)")
                return nil
            }
        }
    }

    private static func loadBoundary(region: ChinaRegion, fileName: String) throws -> RegionBoundary {
        let data = try Data(contentsOf: try boundaryFileURL(named: fileName))
        let json = try JSONSerialization.jsonObject(with: data)
        let geometry = try extractGeometry(from: json)
        return RegionBoundary(region: region, geometry: try parseGeometry(geometry))
    }

    private static func boundaryFileURL(named fileName: String) throws -> URL {
        let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        let deduplicatedBundles = Array(Set(bundles.map(\ .bundleURL))).compactMap(Bundle.init(url:))

        for bundle in deduplicatedBundles {
            if let url = bundle.url(forResource: fileName, withExtension: "json", subdirectory: "BoundaryData") {
                return url
            }
            if let url = bundle.url(forResource: fileName, withExtension: "json") {
                return url
            }
        }

        throw NSError(domain: "ChinaRegionClassifier", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing boundary file \(fileName).json"])
    }

    private static func extractGeometry(from json: Any) throws -> [String: Any] {
        if let dict = json as? [String: Any] {
            if let type = dict["type"] as? String {
                if type == "FeatureCollection",
                   let features = dict["features"] as? [[String: Any]],
                   let geometry = features.first?["geometry"] as? [String: Any] {
                    return geometry
                }

                if type == "Feature", let geometry = dict["geometry"] as? [String: Any] {
                    return geometry
                }

                if type == "Polygon" || type == "MultiPolygon" {
                    return dict
                }
            }

            if let geometry = dict["geojson"] as? [String: Any] {
                return geometry
            }
        }

        if let array = json as? [[String: Any]] {
            if let geometry = array.first(where: {
                guard let geometry = $0["geojson"] as? [String: Any],
                      let type = geometry["type"] as? String else { return false }
                return type == "Polygon" || type == "MultiPolygon"
            })?["geojson"] as? [String: Any] {
                return geometry
            }
        }

        throw NSError(domain: "ChinaRegionClassifier", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported GeoJSON payload"])
    }

    private static func parseGeometry(_ geometry: [String: Any]) throws -> GeoMultiPolygon {
        guard let type = geometry["type"] as? String else {
            throw NSError(domain: "ChinaRegionClassifier", code: 3, userInfo: [NSLocalizedDescriptionKey: "GeoJSON geometry has no type"])
        }

        switch type {
        case "Polygon":
            return GeoMultiPolygon(polygons: [try parsePolygon(geometry["coordinates"])])
        case "MultiPolygon":
            guard let rawPolygons = geometry["coordinates"] as? [Any] else {
                throw NSError(domain: "ChinaRegionClassifier", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid MultiPolygon coordinates"])
            }
            let polygons = try rawPolygons.map(parsePolygon)
            return GeoMultiPolygon(polygons: polygons)
        default:
            throw NSError(domain: "ChinaRegionClassifier", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unsupported geometry type \(type)"])
        }
    }

    private static func parsePolygon(_ rawPolygon: Any?) throws -> GeoPolygon {
        guard let rawRings = rawPolygon as? [Any] else {
            throw NSError(domain: "ChinaRegionClassifier", code: 6, userInfo: [NSLocalizedDescriptionKey: "Invalid Polygon coordinates"])
        }
        let rings = try rawRings.map(parseRing)
        return GeoPolygon(rings: rings)
    }

    private static func parseRing(_ rawRing: Any) throws -> [CLLocationCoordinate2D] {
        guard let rawPoints = rawRing as? [Any] else {
            throw NSError(domain: "ChinaRegionClassifier", code: 7, userInfo: [NSLocalizedDescriptionKey: "Invalid ring coordinates"])
        }

        return try rawPoints.map { rawPoint in
            guard let point = rawPoint as? [Double], point.count >= 2 else {
                throw NSError(domain: "ChinaRegionClassifier", code: 8, userInfo: [NSLocalizedDescriptionKey: "Invalid point coordinates"])
            }
            return CLLocationCoordinate2D(latitude: point[1], longitude: point[0])
        }
    }
}