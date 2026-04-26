import MapKit

// MARK: - GradientPolylineOverlay
// Used for single-day rainbow gradient: one CGColor per coordinate.

final class GradientPolylineOverlay: NSObject, MKOverlay {
    let coordinates: [CLLocationCoordinate2D]
    let colors: [CGColor]

    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(coordinates: [CLLocationCoordinate2D], colors: [CGColor]) {
        self.coordinates = coordinates
        self.colors      = colors

        // Bounding rect
        var minLat =  90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for c in coordinates {
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let centre = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        self.coordinate = centre

        let sw = MKMapPoint(CLLocationCoordinate2D(latitude: minLat, longitude: minLon))
        let ne = MKMapPoint(CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon))
        self.boundingMapRect = MKMapRect(x: min(sw.x, ne.x), y: min(sw.y, ne.y),
                                         width: abs(ne.x - sw.x), height: abs(ne.y - sw.y))
    }
}

// MARK: - GradientPolylineRenderer

final class GradientPolylineRenderer: MKOverlayRenderer {

    private let gradientOverlay: GradientPolylineOverlay

    init(overlay: GradientPolylineOverlay) {
        self.gradientOverlay = overlay
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        let coords = gradientOverlay.coordinates
        let colors = gradientOverlay.colors
        guard coords.count >= 2 else { return }

        let lineWidth:   CGFloat = max(3.0, 6.0 / zoomScale)
        let borderWidth: CGFloat = lineWidth + max(3.0, 6.0 / zoomScale)
        let shadowBlur:  CGFloat = max(5.0, 10.0 / zoomScale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let count = min(coords.count, colors.count)
        let pts: [CGPoint] = coords.prefix(count).map { point(for: MKMapPoint($0)) }

        // Pass 1: ONE continuous path → white border + shadow drawn exactly once.
        // Never draw shadow per-segment; accumulated shadows look dirty.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.0 / zoomScale),
                      blur: shadowBlur,
                      color: CGColor(gray: 0, alpha: 0.3))
        ctx.setLineWidth(borderWidth)
        ctx.setStrokeColor(CGColor(gray: 1.0, alpha: 1.0))
        ctx.beginPath()
        ctx.move(to: pts[0])
        for i in 1 ..< pts.count { ctx.addLine(to: pts[i]) }
        ctx.strokePath()
        ctx.restoreGState()

        // Pass 2: per-segment rainbow gradient on top, no shadow.
        ctx.setLineWidth(lineWidth)
        for i in 0 ..< count - 1 {
            ctx.beginPath()
            ctx.move(to: pts[i])
            ctx.addLine(to: pts[i + 1])
            ctx.setStrokeColor(colors[i])
            ctx.strokePath()
        }
    }

    override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool { true }
}

// MARK: - ColoredPolyline
// Used for multi-day mode: one solid-colour polyline per day.

final class ColoredPolyline: MKPolyline {
    var lineColor: CGColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    var dayDate:   String  = ""
    var dayIndex:  Int     = 0
    var totalDays: Int     = 1
}

// MARK: - ColoredPolylineRenderer
// Draws the day polyline with a white border and soft shadow.

final class ColoredPolylineRenderer: MKOverlayRenderer {
    private let poly: ColoredPolyline

    init(polyline: ColoredPolyline) {
        self.poly = polyline
        super.init(overlay: polyline)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        guard poly.pointCount >= 2 else { return }

        let lineWidth:   CGFloat = max(3.0, 6.0  / zoomScale)
        let borderWidth: CGFloat = lineWidth + max(3.0, 6.0 / zoomScale)
        let shadowBlur:  CGFloat = max(5.0, 10.0 / zoomScale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let pts: [CGPoint] = (0 ..< poly.pointCount).map { point(for: poly.points()[$0]) }

        // Pass 1: ONE continuous path → white border + shadow drawn exactly once.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.0 / zoomScale),
                      blur: shadowBlur,
                      color: CGColor(gray: 0, alpha: 0.18))
        ctx.setLineWidth(borderWidth)
        ctx.setStrokeColor(CGColor(gray: 1.0, alpha: 1.0))
        ctx.beginPath()
        ctx.move(to: pts[0])
        for i in 1 ..< pts.count { ctx.addLine(to: pts[i]) }
        ctx.strokePath()
        ctx.restoreGState()

        // Pass 2: colored line on top, no shadow.
        ctx.setLineWidth(lineWidth)
        ctx.setStrokeColor(poly.lineColor)
        ctx.beginPath()
        ctx.move(to: pts[0])
        for i in 1 ..< pts.count { ctx.addLine(to: pts[i]) }
        ctx.strokePath()
    }

    override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool { true }
}
