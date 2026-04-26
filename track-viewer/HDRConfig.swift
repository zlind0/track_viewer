import CoreGraphics

// MARK: - HDR Configuration
// All HDR-related tuning parameters live here. Adjust to taste.

enum HDRConfig {

    // ── Track appearance: HDR ON ──────────────────────────────────────────────

    /// Extended-range brightness multiplier applied to each linear-light RGB component.
    /// 1.0 = SDR white ceiling. 2.5 ≈ 1.3 stops above white on an EDR display.
    /// Comfortable range: 1.5 – 4.0. Increase for more punch.
    static let trackEDRMultiplier: CGFloat = 1.5

    /// Track hue-saturation-brightness parameters while HDR is ON.
    /// These feed into the HSB → linear-light → EDR pipeline.
    static let trackHDRSaturation: CGFloat = 0.72   // 0–1; higher = more vivid
    static let trackHDRBrightness:  CGFloat = 1.00   // 0–1; keep at 1.0 for max base before EDR

    // ── Track appearance: HDR OFF ─────────────────────────────────────────────

    /// Track saturation and brightness used in standard (non-EDR) mode.
    static let trackSDRSaturation: CGFloat = 0.55
    static let trackSDRBrightness:  CGFloat = 0.92

    // ── Map appearance: HDR OFF ───────────────────────────────────────────────

    /// Opacity of the black dim overlay placed above the map in SDR mode.
    /// 0.0 = no dimming, 0.10 = subtle, 0.30 = noticeably dark.
    static let mapDimOpacity: Double = 0.10

    // ── Rendering performance ─────────────────────────────────────────────────

    /// Number of color bands used when drawing the single-day gradient.
    /// Higher = smoother gradient, more GPU work. 32 is visually indistinguishable
    /// from per-segment and reduces draw calls from ~3600 to 32.
    static let gradientBandCount: Int = 32

    // ── Perceptual luminance equalisation ─────────────────────────────────────
    // Dark hues (blue, violet) are boosted toward `perceptualTargetLuminance`.
    // Red sits at L≈0.21; set the target just above it so red gets only a small
    // nudge while blue (L≈0.07) and violet (L≈0.18) get a meaningful lift.

    /// Target relative luminance. Hues below this get boosted; hues above stay at 1×.
    /// Red ≈ 0.21, violet ≈ 0.18, blue ≈ 0.07. Orange ≈ 0.48, yellow ≈ 0.93.
    static let perceptualTargetLuminance: Double = 0.24

    /// Maximum per-hue boost factor applied on top of `trackEDRMultiplier` in HDR mode.
    static let perceptualMaxBoostHDR: Double = 4
}
