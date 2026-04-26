import MapKit
import Observation

// MARK: - MapRegion
// A dedicated observable holding only the current map region.
// Keeping this separate from AppState means the track Canvas redraws
// 60 fps during pan/zoom while the rest of the UI stays untouched.

@Observable
final class MapRegion {
    var region: MKCoordinateRegion?
}
