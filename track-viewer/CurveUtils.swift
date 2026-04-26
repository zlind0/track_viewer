import CoreLocation

enum CurveUtils {

    /// Catmull-Rom spline: converts a list of GPS coordinates into a smoother path.
    /// Large gaps (>50 km) are treated as breaks and not smoothed across.
    static func catmullRomSpline(
        coordinates: [CLLocationCoordinate2D],
        pointsPerSegment: Int = 6
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 2 else { return coordinates }
        if coordinates.count == 2 {
            return linspace(from: coordinates[0], to: coordinates[1], steps: pointsPerSegment)
        }

        var result: [CLLocationCoordinate2D] = []
        // Pad endpoints so all original points are control-point centres.
        let pts = [coordinates[0]] + coordinates + [coordinates[coordinates.count - 1]]

        for i in 1 ..< pts.count - 2 {
            let p0 = pts[i - 1], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2]

            // Don't interpolate across large GPS gaps.
            if haversineMeters(p1, p2) > 50_000 {
                result.append(p1)
                continue
            }

            for j in 0 ..< pointsPerSegment {
                let t = Double(j) / Double(pointsPerSegment)
                result.append(crPoint(p0: p0, p1: p1, p2: p2, p3: p3, t: t))
            }
        }
        result.append(coordinates[coordinates.count - 1])
        return result
    }

    /// Thin a large coordinate array to at most `maxPoints` evenly spaced points.
    static func downsample(
        _ coordinates: [CLLocationCoordinate2D],
        maxPoints: Int
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maxPoints, maxPoints > 1 else { return coordinates }
        let step = max(1, coordinates.count / maxPoints)
        var result = stride(from: 0, to: coordinates.count, by: step).map { coordinates[$0] }
        // Always keep the last point.
        if let last = coordinates.last,
           let resultLast = result.last,
           (abs(resultLast.latitude - last.latitude) > 1e-9 || abs(resultLast.longitude - last.longitude) > 1e-9) {
            result.append(last)
        }
        return result
    }

    // MARK: Private

    private static func crPoint(
        p0: CLLocationCoordinate2D, p1: CLLocationCoordinate2D,
        p2: CLLocationCoordinate2D, p3: CLLocationCoordinate2D,
        t: Double
    ) -> CLLocationCoordinate2D {
        let t2 = t * t, t3 = t2 * t
        let lat = 0.5 * (
            2 * p1.latitude
            + (-p0.latitude + p2.latitude) * t
            + (2 * p0.latitude - 5 * p1.latitude + 4 * p2.latitude - p3.latitude) * t2
            + (-p0.latitude + 3 * p1.latitude - 3 * p2.latitude + p3.latitude) * t3
        )
        let lon = 0.5 * (
            2 * p1.longitude
            + (-p0.longitude + p2.longitude) * t
            + (2 * p0.longitude - 5 * p1.longitude + 4 * p2.longitude - p3.longitude) * t2
            + (-p0.longitude + 3 * p1.longitude - 3 * p2.longitude + p3.longitude) * t3
        )
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private static func linspace(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D,
        steps: Int
    ) -> [CLLocationCoordinate2D] {
        (0 ... steps).map { i in
            let t = Double(i) / Double(steps)
            return CLLocationCoordinate2D(
                latitude: a.latitude + (b.latitude - a.latitude) * t,
                longitude: a.longitude + (b.longitude - a.longitude) * t
            )
        }
    }

    private static func haversineMeters(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
