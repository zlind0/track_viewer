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

// MARK: - TrackMapView (NSViewRepresentable)

struct TrackMapView: NSViewRepresentable {
    @Bindable var appState: AppState
    let mapRegion: MapRegion

    func makeCoordinator() -> Coordinator { Coordinator(appState: appState, mapRegion: mapRegion) }

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
            }
        }
        mapView.onMouseClicked = { [weak coord = context.coordinator] coordinate in
            coord?.handleMouseClicked(coordinate: coordinate)
        }
        mapView.wantsLayer = true
        return mapView
    }

    func updateNSView(_ mapView: TrackMapViewNS, context: Context) {
        context.coordinator.updateMap(mapView)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var appState: AppState
        let mapRegion: MapRegion
        weak var mapView: TrackMapViewNS?

        private var lastHDREnabled: Bool = false

        // Timer polls mapView.region at 60 fps so TrackCanvas stays in sync
        // during ALL animations and gestures (including programmatic ones).
        private var regionTimer: Timer?

        init(appState: AppState, mapRegion: MapRegion) {
            self.appState  = appState
            self.mapRegion = mapRegion
            super.init()
            regionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) {
                [weak self] _ in
                guard let self, let mv = self.mapView else { return }
                self.mapRegion.region = mv.region
            }
            RunLoop.main.add(regionTimer!, forMode: .common)
        }

        deinit { regionTimer?.invalidate() }

        // MARK: updateMap

        func updateMap(_ mapView: TrackMapViewNS) {
            let hdr = appState.hdrEnabled
            if hdr != lastHDREnabled {
                lastHDREnabled = hdr
                mapView.layer?.wantsExtendedDynamicRangeContent = hdr
            }
            if appState.mapFitRequested {
                fitMap(mapView)
                appState.mapFitRequested = false
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
                appState.trackHoverInfo = TrackHoverInfo(point: pt, screenPosition: screenPoint)
            } else {
                appState.trackHoverInfo = nil
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

        // MARK: MKMapViewDelegate – renderers (no track overlays; tracks drawn by TrackCanvas)

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - Hover Tooltip Overlays (SwiftUI)

struct TrackHoverTooltip: View {
    let info: TrackHoverInfo

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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .frame(width: 190)
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

// MARK: - MapContainer (wraps map + dim + track canvas + tooltips)

struct MapContainer: View {
    @Bindable var appState: AppState
    // MapRegion is owned here so it's not re-created on AppState changes.
    // Only TrackCanvas observes it, keeping pan/zoom redraws isolated.
    @State private var mapRegion = MapRegion()

    var body: some View {
        ZStack(alignment: .topLeading) {
            TrackMapView(appState: appState, mapRegion: mapRegion)

            // SDR dim overlay: sits between the map tiles and the track canvas
            // so tracks (drawn in TrackCanvas above this) are NOT dimmed.
            // Adjust HDRConfig.mapDimOpacity to taste.
            if !appState.hdrEnabled {
                Color.black.opacity(HDRConfig.mapDimOpacity)
                    .allowsHitTesting(false)
            }

            // Unified track canvas for both HDR and SDR.
            // .allowedDynamicRange(.high) enables EDR (> 1.0) values in HDR mode.
            TrackCanvas(appState: appState, mapRegion: mapRegion)
                .allowedDynamicRange(appState.hdrEnabled ? .high : .standard)
                .allowsHitTesting(false)

            // Track-point hover tooltip
            if let info = appState.trackHoverInfo {
                TrackHoverTooltip(info: info)
                    .position(x: info.screenPosition.x + 110,
                              y: info.screenPosition.y - 50)
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

// MARK: - TrackCanvas
// Draws tracks for both SDR and HDR modes via SwiftUI Canvas.
// In HDR mode the call site applies .allowedDynamicRange(.high) and
// ctx.withCGContext lets us write EDR CGColors (> 1.0) directly into
// the wide-gamut buffer without SwiftUI Color clamping them.
//
// Performance: single-day gradient uses HDRConfig.gradientBandCount colour
// bands instead of per-segment strokes, cutting draw calls from ~3600 to 32.

struct TrackCanvas: View {
    let appState: AppState
    let mapRegion: MapRegion

    var body: some View {
        // Snapshot all value types here (MainActor) before entering the
        // @Sendable Canvas closure.
        let region       = mapRegion.region
        let viewMode     = appState.viewMode
        let smoothCoords = appState.currentDaySmoothedCoords
        let multiCoords  = appState.multiDayCoords
        let multiSums    = appState.multiDaySummaries
        let hdr          = appState.hdrEnabled

        Canvas { ctx, size in
            guard let region,
                  region.span.longitudeDelta > 0,
                  size.width > 0 else { return }

            // Web Mercator projection matching MapKit's tile coordinate system.
            let scale = size.width / region.span.longitudeDelta
            let cLat  = region.center.latitude
            let cLon  = region.center.longitude
            let mYc   = log(tan(.pi / 4 + cLat * .pi / 360))

            func geo(_ c: CLLocationCoordinate2D) -> CGPoint {
                let dx =  (c.longitude - cLon) * scale
                let dy = -(log(tan(.pi / 4 + c.latitude * .pi / 360)) - mYc) * scale * (180 / .pi)
                return CGPoint(x: size.width / 2 + dx, y: size.height / 2 + dy)
            }

            // withCGContext writes raw CGColors into the Canvas's wide-gamut
            // backing buffer, preserving EDR components > 1.0 for HDR mode.
            ctx.withCGContext { cgCtx in
                cgCtx.setLineWidth(3)
                cgCtx.setLineCap(.round)
                cgCtx.setLineJoin(.round)

                switch viewMode {
                case .singleDay, .singleDayFromMulti:
                    let n = smoothCoords.count
                    guard n >= 2 else { return }
                    // Band-based gradient: divide track into N colour bands.
                    // Reduces draw calls from O(n) to O(gradientBandCount).
                    let bands = HDRConfig.gradientBandCount
                    for band in 0 ..< bands {
                        let i0 = (n - 1) * band / bands
                        let i1 = min((n - 1) * (band + 1) / bands, n - 2)
                        guard i0 <= i1 else { continue }
                        let progress = Double(i0) / Double(n - 1)
                        let color = hdr
                            ? ColorUtils.rainbowPastelCGColorHDR(progress: progress)
                            : ColorUtils.rainbowPastelCGColor(progress: progress)
                        cgCtx.setStrokeColor(color)
                        cgCtx.beginPath()
                        cgCtx.move(to: geo(smoothCoords[i0]))
                        for i in (i0 + 1) ... (i1 + 1) {
                            cgCtx.addLine(to: geo(smoothCoords[i]))
                        }
                        cgCtx.strokePath()
                    }

                case .multiDay:
                    let total = multiSums.count
                    for (idx, summary) in multiSums.enumerated() {
                        guard let coords = multiCoords[summary.date],
                              coords.count >= 2 else { continue }
                        let color = hdr
                            ? ColorUtils.discreteRainbowCGColorHDR(index: idx, total: total)
                            : ColorUtils.discreteRainbowCGColor(index: idx, total: total)
                        cgCtx.setStrokeColor(color)
                        cgCtx.beginPath()
                        cgCtx.move(to: geo(coords[0]))
                        for i in 1 ..< coords.count { cgCtx.addLine(to: geo(coords[i])) }
                        cgCtx.strokePath()
                    }
                }
            }
        }
    }
}
