//
//  track_viewerTests.swift
//  track-viewerTests
//
//  Created by lin on 2026/04/26.
//

import Testing
import CoreLocation
@testable import track_viewer

struct track_viewerTests {

    @Test func chinaRegionClassificationUsesPreciseBoundaries() async throws {
        #expect(region(lat: 39.9042, lon: 116.4074) == .mainlandChina)
        #expect(region(lat: 22.2793, lon: 114.1628) == .hongKong)
        #expect(region(lat: 22.1987, lon: 113.5439) == .macau)
        #expect(region(lat: 25.0330, lon: 121.5654) == .taiwan)
        #expect(region(lat: 34.6937, lon: 135.5023) == .outside)
    }

    @Test func mainlandGateRejectsKnownNonMainlandLocations() async throws {
        #expect(CoordinateConverter.isInMainlandChina(lat: 34.6937, lon: 135.5023) == false)
        #expect(CoordinateConverter.isInMainlandChina(lat: 22.2793, lon: 114.1628) == false)
        #expect(CoordinateConverter.isInMainlandChina(lat: 22.1987, lon: 113.5439) == false)
        #expect(CoordinateConverter.isInMainlandChina(lat: 25.0330, lon: 121.5654) == false)
        #expect(CoordinateConverter.isInMainlandChina(lat: 39.9042, lon: 116.4074) == true)
    }

    private func region(lat: Double, lon: Double) -> ChinaRegion {
        CoordinateConverter.region(for: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

}
