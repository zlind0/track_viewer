import CoreLocation

// MARK: - CoordinateConverter
// Converts WGS-84 → GCJ-02 for display in MapKit on macOS.
//
// The raw GPS data in the track files is stored in WGS-84 (standard GPS).
// However, MapKit on Apple platforms in mainland China uses GCJ-02 map tiles
// internally and expects GCJ-02 coordinates from the caller.  If we feed it
// raw WGS-84, the displayed position is shifted 100–500 m.
//
// Fix: convert WGS-84 → GCJ-02 (add the Krasovsky ellipsoid offset) so that
// MapKit's own internal correction cancels out, giving correct display.
//
// Algorithm: standard Krasovsky 1940 ellipsoid transform (eviltransform/coordtransform).

enum CoordinateConverter {

    // MARK: - Public

    /// Returns the coordinate converted from WGS-84 to GCJ-02 if it falls inside
    /// mainland China so that MapKit displays it in the correct position.
    /// Outside mainland China the coordinate is returned unchanged.
    static func gcj02ToWgs84(_ coord: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isInMainlandChina(lat: coord.latitude, lon: coord.longitude) else {
            return coord
        }
        let (dLat, dLon) = gcjOffset(lat: coord.latitude, lon: coord.longitude)
        return CLLocationCoordinate2D(
            latitude:  coord.latitude  + dLat,
            longitude: coord.longitude + dLon
        )
    }

    static func region(for coord: CLLocationCoordinate2D) -> ChinaRegion {
        ChinaRegionClassifier.region(for: coord)
    }

    // MARK: - Mainland China Boundary

    static func isInMainlandChina(lat: Double, lon: Double) -> Bool {
        region(for: CLLocationCoordinate2D(latitude: lat, longitude: lon)) == .mainlandChina
    }

    // MARK: - GCJ-02 Forward Offset (Krasovsky 1940 ellipsoid)

    /// Computes (dLat, dLon): the amount to ADD to WGS-84 to get GCJ-02.
    /// Subtract it from a GCJ-02 coordinate to recover WGS-84 (approximate inverse).
    private static let semiMajor = 6_378_245.0          // a — metres
    private static let eSquared  = 0.006_693_421_622_966 // e²

    private static func gcjOffset(lat wgsLat: Double, lon wgsLon: Double) -> (dLat: Double, dLon: Double) {
        var dLat = transformLat(x: wgsLon - 105.0, y: wgsLat - 35.0)
        var dLon = transformLon(x: wgsLon - 105.0, y: wgsLat - 35.0)

        let radLat   = wgsLat / 180.0 * .pi
        var magic    = sin(radLat)
        magic        = 1 - eSquared * magic * magic
        let sqrtMag  = magic.squareRoot()

        dLat = dLat * 180.0 / ((semiMajor * (1 - eSquared)) / (magic * sqrtMag) * .pi)
        dLon = dLon * 180.0 / (semiMajor / sqrtMag * cos(radLat) * .pi)

        return (dLat, dLon)
    }

    private static func transformLat(x: Double, y: Double) -> Double {
        var v = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * abs(x).squareRoot()
        v += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        v += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi))        * 2.0 / 3.0
        v += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return v
    }

    private static func transformLon(x: Double, y: Double) -> Double {
        var v = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * abs(x).squareRoot()
        v += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        v += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi))        * 2.0 / 3.0
        v += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return v
    }
}
