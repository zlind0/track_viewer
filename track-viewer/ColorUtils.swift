import SwiftUI
import AppKit

enum ColorUtils {

    // MARK: - GitHub Heatmap

    /// Returns a GitHub-style green based on `intensity` ∈ [0, 1].
    static func heatmapColor(intensity: Double) -> Color {
        Color(nsColor: heatmapNSColor(intensity: intensity))
    }

    static func heatmapNSColor(intensity: Double) -> NSColor {
        let t = max(0, min(1, intensity))
        guard t > 0.001 else {
            return NSColor(calibratedRed: 0.87, green: 0.87, blue: 0.87, alpha: 1)
        }
        // Palette: #9BE9A8 → #40C463 → #30A14E → #216E39
        let stops: [(t: Double, r: Double, g: Double, b: Double)] = [
            (0.00, 0.608, 0.914, 0.659),
            (0.33, 0.251, 0.769, 0.388),
            (0.67, 0.188, 0.635, 0.306),
            (1.00, 0.129, 0.431, 0.224),
        ]
        for i in 0 ..< stops.count - 1 {
            let s1 = stops[i], s2 = stops[i + 1]
            if t <= s2.t {
                let f = (t - s1.t) / (s2.t - s1.t)
                return NSColor(calibratedRed: s1.r + (s2.r - s1.r) * f,
                               green: s1.g + (s2.g - s1.g) * f,
                               blue: s1.b + (s2.b - s1.b) * f,
                               alpha: 1)
            }
        }
        let last = stops.last!
        return NSColor(calibratedRed: last.r, green: last.g, blue: last.b, alpha: 1)
    }

    // MARK: - Rainbow Pastel (single-day gradient, red→purple)

    /// `progress` ∈ [0, 1]: 0 = start of day (red), 1 = end of day (purple).
    static func rainbowPastelNSColor(progress: Double) -> NSColor {
        let hue = max(0, min(1, progress)) * 0.75   // 0 (red) → 0.75 (purple)
        return NSColor(calibratedHue: hue,
                       saturation: HDRConfig.trackSDRSaturation,
                       brightness: HDRConfig.trackSDRBrightness,
                       alpha: 1)
    }

    static func rainbowPastelCGColor(progress: Double) -> CGColor {
        rainbowPastelNSColor(progress: progress).cgColor
    }

    // MARK: - Discrete Rainbow (multi-day, one colour per day)

    /// `index` ∈ [0, total-1]: 0 = red (first day), total-1 = purple (last day).
    static func discreteRainbowNSColor(index: Int, total: Int) -> NSColor {
        guard total > 0 else { return .systemRed }
        let t = total == 1 ? 0.0 : Double(index) / Double(total - 1)
        return NSColor(calibratedHue: t * 0.75,
                       saturation: HDRConfig.trackSDRSaturation,
                       brightness: HDRConfig.trackSDRBrightness,
                       alpha: 1)
    }

    static func discreteRainbowCGColor(index: Int, total: Int) -> CGColor {
        discreteRainbowNSColor(index: index, total: total).cgColor
    }

    // MARK: - EDR / HDR variants
    // Colors in CGColorSpace.extendedLinearSRGB with component values > 1.0 render
    // brighter than SDR white on an EDR (Extended Dynamic Range) display.

    /// Converts a calibrated HSB colour to linear light, multiplies by `HDRConfig.trackEDRMultiplier`,
    /// and places the result in the extendedLinearSRGB colour space for EDR rendering.
    private static func edrColor(hue: Double, saturation: CGFloat, brightness: CGFloat) -> CGColor {
        let ns = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        // Convert to generic RGB so getRed works reliably
        guard let rgb = ns.usingColorSpace(.genericRGB) else { return ns.cgColor }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: nil)

        // sRGB → linear light (remove gamma)
        func toLinear(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let m = HDRConfig.trackEDRMultiplier
        let comps: [CGFloat] = [toLinear(r) * m, toLinear(g) * m, toLinear(b) * m, 1.0]

        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return ns.cgColor }
        return CGColor(colorSpace: space, components: comps) ?? ns.cgColor
    }

    /// HDR single-day gradient colour. `progress` ∈ [0, 1].
    static func rainbowPastelCGColorHDR(progress: Double) -> CGColor {
        let hue = max(0, min(1, progress)) * 0.75
        return edrColor(hue: hue,
                        saturation: HDRConfig.trackHDRSaturation,
                        brightness: HDRConfig.trackHDRBrightness)
    }

    /// HDR multi-day colour. `index` ∈ [0, total-1].
    static func discreteRainbowCGColorHDR(index: Int, total: Int) -> CGColor {
        guard total > 0 else { return CGColor(red: 1, green: 0, blue: 0, alpha: 1) }
        let hue = total == 1 ? 0.0 : Double(index) / Double(total - 1) * 0.75
        return edrColor(hue: hue,
                        saturation: HDRConfig.trackHDRSaturation,
                        brightness: HDRConfig.trackHDRBrightness)
    }
}
