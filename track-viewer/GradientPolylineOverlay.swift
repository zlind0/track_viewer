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

        let lineWidth = max(2.0, 4.0 / zoomScale)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let count = min(coords.count, colors.count)
        for i in 0 ..< count - 1 {
            let p1 = point(for: MKMapPoint(coords[i]))
            let p2 = point(for: MKMapPoint(coords[i + 1]))
            ctx.beginPath()
            ctx.move(to: p1)
            ctx.addLine(to: p2)
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
