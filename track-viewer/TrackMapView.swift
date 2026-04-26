import SwiftUI
import MapKit

// MARK: - TrackMapViewNS
// MKMapView subclass that forwards mouse events for hover tooltips.

final class TrackMapViewNS: MKMapView {
    var onMouseMoved:  ((CLLocationCoordinate2D, CGPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    var onMouseClicked: ((CLLocationCoordinate2D) -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let loc = convert(event.locationInWindow, from: nil)
        let coord = convert(loc, toCoordinateFrom: self)
        onMouseMoved?(coord, loc)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExited?()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let loc = convert(event.locationInWindow, from: nil)
        let coord = convert(loc, toCoordinateFrom: self)
        onMouseClicked?(coord)
    }
}

// MARK: - HoverPointAnnotation

final class HoverPointAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate }
}

// MARK: - TrackMapView (NSViewRepresentable)

struct TrackMapView: NSViewRepresentable {
    @Bindable var appState: AppState

    func makeCoordinator() -> Coordinator { Coordinator(appState: appState) }

    func makeNSView(context: Context) -> TrackMapViewNS {
        let mapView = TrackMapViewNS()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale   = true
        mapView.mapType      = .standard

        context.coordinator.mapView = mapView

        mapView.onMouseMoved = { [weak coord = context.coordinator] coordinate, screenPt in
            coord?.handleMouseMoved(coordinate: coordinate, screenPoint: screenPt)
        }
        mapView.onMouseExited = { [weak coord = context.coordinator] in
            Task { @MainActor in
                coord?.appState.trackHoverInfo = nil
                coord?.appState.dayHoverInfo   = nil
                coord?.removeHoverAnnotation()
            }
        }
        mapView.onMouseClicked = { [weak coord = context.coordinator] coordinate in
            coord?.handleMouseClicked(coordinate: coordinate)
        }
        return mapView
    }

    func updateNSView(_ mapView: TrackMapViewNS, context: Context) {
        context.coordinator.updateMap(mapView)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var appState: AppState
        weak var mapView: TrackMapViewNS?

        // Cached state to avoid redundant redraws
        private var lastMode:         ViewMode?
        private var lastSelectedDate: String?
        private var lastMultiStart:   Date?
        private var lastMultiEnd:     Date?
        private var lastPointCount:   Int = 0
        private var lastMultiDayCount: Int = 0

        // Hover point annotation (single-day mode)
        private var hoverAnnotation: HoverPointAnnotation?

        init(appState: AppState) { self.appState = appState }

        // MARK: updateMap

        func updateMap(_ mapView: TrackMapViewNS) {
            let mode        = appState.viewMode
            let selDate     = appState.selectedDate
            let multiStart  = appState.multiDayStart
            let multiEnd    = appState.multiDayEnd
            let pointCount  = appState.currentDayPoints.count
            let multiCount  = appState.multiDayCoords.count

            // Guard against redundant redraws
            let sameState = mode        == lastMode
                         && selDate     == lastSelectedDate
                         && multiStart  == lastMultiStart
                         && multiEnd    == lastMultiEnd
                         && pointCount  == lastPointCount
                         && multiCount  == lastMultiDayCount

            if sameState && !appState.mapFitRequested { return }

            lastMode          = mode
            lastSelectedDate  = selDate
            lastMultiStart    = multiStart
            lastMultiEnd      = multiEnd
            lastPointCount    = pointCount
            lastMultiDayCount = multiCount

            removeHoverAnnotation()  // clear stale hover when track changes
            mapView.removeOverlays(mapView.overlays)

            switch mode {
            case .singleDay, .singleDayFromMulti:
                renderSingleDay(mapView)
            case .multiDay:
                renderMultiDay(mapView)
            }

            if appState.mapFitRequested {
                fitMap(mapView)
                appState.mapFitRequested = false
            }
        }

        // MARK: Single Day

        private func renderSingleDay(_ mapView: MKMapView) {
            let points = appState.currentDayPoints
            guard points.count >= 2 else { return }

            let allCoords = points.map(\.wgs84Coordinate)
            let down      = CurveUtils.downsample(allCoords, maxPoints: 600)
            let smooth    = CurveUtils.catmullRomSpline(coordinates: down, pointsPerSegment: 6)

            let n = smooth.count
            let colors: [CGColor] = (0 ..< n).map { i in
                ColorUtils.rainbowPastelCGColor(progress: Double(i) / Double(max(n - 1, 1)))
            }
            let overlay = GradientPolylineOverlay(coordinates: smooth, colors: colors)
            mapView.addOverlay(overlay, level: .aboveRoads)
        }

        // MARK: Multi Day

        private func renderMultiDay(_ mapView: MKMapView) {
            let summaries = appState.multiDaySummaries
            let total     = summaries.count
            for (idx, summary) in summaries.enumerated() {
                guard let coords = appState.multiDayCoords[summary.date],
                      coords.count >= 2 else { continue }
                let polyline = ColoredPolyline(coordinates: coords, count: coords.count)
                polyline.lineColor = ColorUtils.discreteRainbowCGColor(index: idx, total: total)
                polyline.dayDate   = summary.date
                polyline.dayIndex  = idx
                polyline.totalDays = total
                mapView.addOverlay(polyline, level: .aboveRoads)
            }
        }

        // MARK: Fit Map

        private func fitMap(_ mapView: MKMapView) {
            var rect = MKMapRect.null

            switch appState.viewMode {
            case .singleDay, .singleDayFromMulti:
                for pt in appState.currentDayPoints {
                    let mp = MKMapPoint(pt.wgs84Coordinate)
                    rect = rect.union(MKMapRect(x: mp.x, y: mp.y, width: 0, height: 0))
                }
            case .multiDay:
                for coords in appState.multiDayCoords.values {
                    for c in coords {
                        let mp = MKMapPoint(c)
                        rect = rect.union(MKMapRect(x: mp.x, y: mp.y, width: 0, height: 0))
                    }
                }
            }

            guard !rect.isNull, rect.size.width > 0, rect.size.height > 0 else {
                mapView.setRegion(MKCoordinateRegion(.world), animated: true)
                return
            }

            // Expand to 70% coverage
            let padded = rect.insetBy(dx: -rect.size.width * 0.22,
                                      dy: -rect.size.height * 0.22)
            mapView.setVisibleMapRect(padded, edgePadding: NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: true)
        }

        // MARK: Hover Handling

        func handleMouseMoved(coordinate: CLLocationCoordinate2D, screenPoint: CGPoint) {
            Task { @MainActor in
                switch appState.viewMode {
                case .singleDay, .singleDayFromMulti:
                    self.updateTrackHover(coordinate: coordinate, screenPoint: screenPoint)
                case .multiDay:
                    self.updateDayHover(coordinate: coordinate, screenPoint: screenPoint)
                }
            }
        }

        private func updateTrackHover(coordinate: CLLocationCoordinate2D, screenPoint: CGPoint) {
            let points = appState.currentDayPoints
            guard !points.isEmpty else { return }

            // Find nearest point by lat/lon distance
            var best: TrackPoint?
            var bestDist = Double.greatestFiniteMagnitude
            let threshold = 0.002   // ~200m in degrees

            for pt in points {
                let wgs = pt.wgs84Coordinate
                let dLat = wgs.latitude  - coordinate.latitude
                let dLon = wgs.longitude - coordinate.longitude
                let d    = dLat * dLat + dLon * dLon
                if d < bestDist {
                    bestDist = d
                    best     = pt
                }
            }
            if let pt = best, bestDist < threshold * threshold {
                // Convert the track point's geographic coord to map-view screen position
                let wgs = pt.wgs84Coordinate
                let ptScreen: CGPoint = mapView.map {
                    $0.convert(wgs, toPointTo: $0)
                } ?? screenPoint

                appState.trackHoverInfo = TrackHoverInfo(point: pt, screenPosition: ptScreen)

                // Place or move the enlarged dot annotation
                if let ann = hoverAnnotation {
                    ann.coordinate = wgs
                } else {
                    let ann = HoverPointAnnotation(coordinate: wgs)
                    mapView?.addAnnotation(ann)
                    hoverAnnotation = ann
                }
            } else {
                appState.trackHoverInfo = nil
                removeHoverAnnotation()
            }
        }

        func removeHoverAnnotation() {
            if let ann = hoverAnnotation {
                mapView?.removeAnnotation(ann)
                hoverAnnotation = nil
            }
        }

        private func updateDayHover(coordinate: CLLocationCoordinate2D, screenPoint: CGPoint) {
            let summaries = appState.multiDaySummaries
            guard !summaries.isEmpty else { return }

            var bestDate: String?
            var bestDist = Double.greatestFiniteMagnitude
            let threshold = 0.005

            for summary in summaries {
                guard let coords = appState.multiDayCoords[summary.date] else { continue }
                for c in coords {
                    let dLat = c.latitude  - coordinate.latitude
                    let dLon = c.longitude - coordinate.longitude
                    let d    = dLat * dLat + dLon * dLon
                    if d < bestDist {
                        bestDist = d
                        bestDate = summary.date
                    }
                }
            }

            if let date = bestDate, bestDist < threshold * threshold,
               let summary = appState.summaryByDate[date] {
                appState.dayHoverInfo = DayHoverInfo(
                    dateStr: date,
                    distanceKm: summary.totalDistanceKm,
                    screenPosition: screenPoint
                )
            } else {
                appState.dayHoverInfo = nil
            }
        }

        func handleMouseClicked(coordinate: CLLocationCoordinate2D) {
            guard appState.viewMode == .multiDay else { return }

            let summaries = appState.multiDaySummaries
            var bestDate: String?
            var bestDist = Double.greatestFiniteMagnitude
            let threshold = 0.005

            for summary in summaries {
                guard let coords = appState.multiDayCoords[summary.date] else { continue }
                for c in coords {
                    let dLat = c.latitude  - coordinate.latitude
                    let dLon = c.longitude - coordinate.longitude
                    let d    = dLat * dLat + dLon * dLon
                    if d < bestDist { bestDist = d; bestDate = summary.date }
                }
            }

            if let date = bestDate, bestDist < threshold * threshold {
                Task { @MainActor in
                    await self.appState.drillDownToDay(date)
                }
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is HoverPointAnnotation else { return nil }
            let id   = "hoverDot"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation      = annotation
            view.canShowCallout  = false
            view.centerOffset    = .zero

            let size: CGFloat = 12
            view.frame.size = CGSize(width: size, height: size)
            let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
                let inset = NSRect(x: 2, y: 2, width: size - 4, height: size - 4)
                let circle = NSBezierPath(ovalIn: inset)
                circle.lineWidth = 2
                NSColor.white.withAlphaComponent(0.95).setFill()
                circle.fill()
                NSColor(white: 0.25, alpha: 0.85).setStroke()
                circle.stroke()
                return true
            }
            view.image = img
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let grad = overlay as? GradientPolylineOverlay {
                return GradientPolylineRenderer(overlay: grad)
            }
            if let poly = overlay as? ColoredPolyline {
                return ColoredPolylineRenderer(polyline: poly)
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - CalloutBubble (rounded rect + downward arrow)

struct CalloutBubble: Shape {
    var cornerRadius: CGFloat = 8
    var arrowWidth:   CGFloat = 14
    var arrowHeight:  CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY,
                          width: rect.width, height: rect.height - arrowHeight)
        var path = Path(roundedRect: body, cornerRadius: cornerRadius)
        let mid  = rect.midX
        path.move(to:    CGPoint(x: mid - arrowWidth / 2, y: body.maxY))
        path.addLine(to: CGPoint(x: mid,                  y: rect.maxY))
        path.addLine(to: CGPoint(x: mid + arrowWidth / 2, y: body.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Hover Tooltip Overlays (SwiftUI)

struct TrackHoverTooltip: View {
    let info: TrackHoverInfo

    private let arrowHeight: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(info.point.localTimeString)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
                GridRow {
                    Text("纬度").foregroundStyle(.secondary)
                    Text(String(format: "%.6f°", info.point.latitude))
                }
                GridRow {
                    Text("经度").foregroundStyle(.secondary)
                    Text(String(format: "%.6f°", info.point.longitude))
                }
                GridRow {
                    Text("海拔").foregroundStyle(.secondary)
                    Text(String(format: "%.1f m", info.point.altitude))
                }
            }
            .font(.system(size: 11))
        }
        .padding(8)
        .padding(.bottom, arrowHeight)  // reserve space for arrow tip
        .frame(width: 190)
        .background {
            CalloutBubble(cornerRadius: 8, arrowWidth: 14, arrowHeight: arrowHeight)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
    }
}

struct DayHoverTooltip: View {
    let info: DayHoverInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(info.dateStr)
                .font(.system(size: 11, weight: .semibold))
            Text(String(format: "%.1f km", info.distanceKm))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}

// MARK: - MapContainer (wraps map + tooltips)

struct MapContainer: View {
    @Bindable var appState: AppState

    var body: some View {
        ZStack(alignment: .topLeading) {
            TrackMapView(appState: appState)

            // Track-point hover tooltip — pinned to the track point, arrow pointing down
            if let info = appState.trackHoverInfo {
                TrackHoverTooltip(info: info)
                    // center.y = pointY - half-height so the arrow tip lands on the point
                    // estimated total height ≈ 88 pt (content 72 + padding 8 + arrow 8)
                    .position(x: info.screenPosition.x,
                              y: info.screenPosition.y - 44)
                    .allowsHitTesting(false)
            }

            // Day hover tooltip (multi-day mode)
            if let info = appState.dayHoverInfo {
                DayHoverTooltip(info: info)
                    .position(x: info.screenPosition.x + 70,
                              y: info.screenPosition.y - 30)
                    .allowsHitTesting(false)
            }
        }
    }
}
