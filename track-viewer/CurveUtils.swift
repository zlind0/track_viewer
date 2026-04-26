import CoreLocation

// MARK: - Thresholds

private let kFlightGapMeters:  Double = 200_000   // >200 km → treat as flight arc
private let kGpsBreakMeters:   Double =  50_000   // >50 km but ≤200 km → GPS break, straight line
private let kFlightArcSteps:   Int    = 32         // interpolation steps per flight arc

enum CurveUtils {

    // MARK: - Catmull-Rom Spline

    /// Converts a list of GPS coordinates into a smooth path.
    ///
    /// Segment handling:
    ///   - Gap < 50 km  → Catmull-Rom smoothing
    ///   - Gap 50–200 km → GPS break; straight line segment, no smoothing
    ///   - Gap > 200 km  → Great-circle arc (correct 2-D projection of flight paths)
    static func catmullRomSpline(
        coordinates: [CLLocationCoordinate2D],
        pointsPerSegment: Int = 6
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 2 else { return coordinates }
        if coordinates.count == 2 {
            let dist = haversineMeters(coordinates[0], coordinates[1])
            if dist > kFlightGapMeters {
                return greatCircleArc(from: coordinates[0], to: coordinates[1], steps: kFlightArcSteps)
            }
            return linspace(from: coordinates[0], to: coordinates[1], steps: pointsPerSegment)
        }

        var result: [CLLocationCoordinate2D] = []
        // Pad endpoints so all original points are control-point centres.
        let pts = [coordinates[0]] + coordinates + [coordinates[coordinates.count - 1]]

        for i in 1 ..< pts.count - 2 {
            let p0 = pts[i - 1], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2]
            let gap = haversineMeters(p1, p2)

            if gap > kFlightGapMeters {
                // Long-haul flight: insert great-circle arc, then restart smoothing.
                result.append(p1)
                let arc = greatCircleArc(from: p1, to: p2, steps: kFlightArcSteps)
                result.append(contentsOf: arc.dropFirst().dropLast())
                continue
            }

            if gap > kGpsBreakMeters {
                // Regular GPS recording break: just mark the endpoint, no smooth.
                result.append(p1)
                continue
            }

            for j in 0 ..< pointsPerSegment {
                let t = Double(j) / Double(pointsPerSegment)
                result.append(crPointCentripetal(p0: p0, p1: p1, p2: p2, p3: p3, t: t))
            }
        }
        result.append(coordinates[coordinates.count - 1])
        return result
    }

    // MARK: - Great-Circle Arc

    /// Interpolates `steps+1` points along the great-circle (geodesic) between two
    /// coordinates using spherical SLERP.  The result correctly projects as a curved
    /// arc on any 2-D Mercator map for long distances.
    static func greatCircleArc(
        from a: CLLocationCoordinate2D,
        to b:   CLLocationCoordinate2D,
        steps:  Int = kFlightArcSteps
    ) -> [CLLocationCoordinate2D] {
        guard steps > 0 else { return [a, b] }

        let lat1 = a.latitude  * .pi / 180,  lon1 = a.longitude * .pi / 180
        let lat2 = b.latitude  * .pi / 180,  lon2 = b.longitude * .pi / 180

        // Cartesian unit vectors on the unit sphere
        let x1 = cos(lat1) * cos(lon1), y1 = cos(lat1) * sin(lon1), z1 = sin(lat1)
        let x2 = cos(lat2) * cos(lon2), y2 = cos(lat2) * sin(lon2), z2 = sin(lat2)

        let dot   = max(-1.0, min(1.0, x1 * x2 + y1 * y2 + z1 * z2))
        let omega = acos(dot)

        // If points are virtually identical, skip the arc.
        guard omega > 1e-10 else { return [a, b] }
        let sinOmega = sin(omega)

        return (0 ... steps).map { step in
            let t  = Double(step) / Double(steps)
            let fa = sin((1 - t) * omega) / sinOmega
            let fb = sin(t       * omega) / sinOmega
            let x  = fa * x1 + fb * x2
            let y  = fa * y1 + fb * y2
            let z  = fa * z1 + fb * z2
            let lat = atan2(z, (x * x + y * y).squareRoot()) * 180 / .pi
            let lon = atan2(y, x) * 180 / .pi
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
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

    /// Centripetal Catmull-Rom via the Barry-Goldman algorithm.
    ///
    /// Knot spacing = distance^0.5  (alpha = 0.5).  This parameterisation
    /// guarantees no cusps or self-intersections, and — crucially — when the
    /// p0→p1 segment is very long (GPS break), its influence on the tangent
    /// at p1 shrinks to zero automatically, eliminating false spikes.
    private static func crPointCentripetal(
        p0: CLLocationCoordinate2D, p1: CLLocationCoordinate2D,
        p2: CLLocationCoordinate2D, p3: CLLocationCoordinate2D,
        t: Double   // 0…1 over the p1→p2 segment
    ) -> CLLocationCoordinate2D {
        let d01 = max(1e-4, pow(haversineMeters(p0, p1), 0.5))
        let d12 = max(1e-4, pow(haversineMeters(p1, p2), 0.5))
        let d23 = max(1e-4, pow(haversineMeters(p2, p3), 0.5))

        let t0 = 0.0
        let t1 = d01
        let t2 = t1 + d12
        let t3 = t2 + d23
        let tc = t1 + t * d12   // actual parameter in [t1, t2]

        // Linear blend helper (avoids division by zero via the max above).
        func blend(_ va: Double, _ vb: Double, _ ta: Double, _ tb: Double) -> Double {
            (va * (tb - tc) + vb * (tc - ta)) / (tb - ta)
        }

        // Level 1
        let a1lat = blend(p0.latitude,  p1.latitude,  t0, t1)
        let a1lon = blend(p0.longitude, p1.longitude, t0, t1)
        let a2lat = blend(p1.latitude,  p2.latitude,  t1, t2)
        let a2lon = blend(p1.longitude, p2.longitude, t1, t2)
        let a3lat = blend(p2.latitude,  p3.latitude,  t2, t3)
        let a3lon = blend(p2.longitude, p3.longitude, t2, t3)

        // Level 2
        let b1lat = blend(a1lat, a2lat, t0, t2)
        let b1lon = blend(a1lon, a2lon, t0, t2)
        let b2lat = blend(a2lat, a3lat, t1, t3)
        let b2lon = blend(a2lon, a3lon, t1, t3)

        // Level 3
        return CLLocationCoordinate2D(
            latitude:  blend(b1lat, b2lat, t1, t2),
            longitude: blend(b1lon, b2lon, t1, t2)
        )
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
