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
        let boost = perceptualBoost(hue: hue, maxBoost: 1.0 / Double(HDRConfig.trackSDRBrightness))
        let adjustedBrightness = min(1.0, HDRConfig.trackSDRBrightness * boost)
        return NSColor(calibratedHue: hue,
                       saturation: HDRConfig.trackSDRSaturation,
                       brightness: adjustedBrightness,
                       alpha: 1)
    }

    static func rainbowPastelCGColor(progress: Double) -> CGColor {
        rainbowPastelNSColor(progress: progress).cgColor
    }

    // MARK: - Discrete Rainbow (multi-day, one colour per day)

    /// `index` ∈ [0, total-1]: 0 = red (first day), total-1 = purple (last day).
    static func discreteRainbowNSColor(index: Int, total: Int) -> NSColor {
        guard total > 0 else { return .systemRed }
        let hue = (total == 1 ? 0.0 : Double(index) / Double(total - 1)) * 0.75
        let boost = perceptualBoost(hue: hue, maxBoost: 1.0 / Double(HDRConfig.trackSDRBrightness))
        let adjustedBrightness = min(1.0, HDRConfig.trackSDRBrightness * boost)
        return NSColor(calibratedHue: hue,
                       saturation: HDRConfig.trackSDRSaturation,
                       brightness: adjustedBrightness,
                       alpha: 1)
    }

    static func discreteRainbowCGColor(index: Int, total: Int) -> CGColor {
        discreteRainbowNSColor(index: index, total: total).cgColor
    }

    // MARK: - EDR / HDR variants
    // Colors in CGColorSpace.extendedLinearSRGB with component values > 1.0 render
    // brighter than SDR white on an EDR (Extended Dynamic Range) display.

    // MARK: Perceptual luminance compensation

    /// Approximate relative luminance of a fully-saturated HSB colour at `hue` ∈ [0, 1].
    /// Uses the standard Rec.709 coefficients (0.2126 R + 0.7152 G + 0.0722 B).
    private static func relativeLuminance(hue: Double) -> Double {
        let h6 = (hue * 6.0).truncatingRemainder(dividingBy: 6.0)
        let i  = Int(h6), f = h6 - Double(i)
        let r, g, b: Double
        switch i {
        case 0:  r = 1;   g = f;   b = 0
        case 1:  r = 1-f; g = 1;   b = 0
        case 2:  r = 0;   g = 1;   b = f
        case 3:  r = 0;   g = 1-f; b = 1
        case 4:  r = f;   g = 0;   b = 1
        default: r = 1;   g = 0;   b = 1-f
        }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Brightness multiplier that perceptually equalises the rainbow.
    /// Dark hues (blue, violet) get boosted; bright hues (yellow, cyan) stay at 1.0.
    private static func perceptualBoost(hue: Double, maxBoost: Double) -> CGFloat {
        let lum = relativeLuminance(hue: hue)
        let target = HDRConfig.perceptualTargetLuminance
        return CGFloat(min(maxBoost, max(1.0, target / max(lum, 0.01))))
    }

    /// Converts a calibrated HSB colour to linear light, multiplies by `HDRConfig.trackEDRMultiplier`,
    /// and places the result in the extendedLinearSRGB colour space for EDR rendering.
    /// A per-hue perceptual boost is also applied so dark hues (red, blue) match
    /// the perceived brightness of bright hues (yellow, cyan).
    private static func edrColor(hue: Double, saturation: CGFloat, brightness: CGFloat) -> CGColor {
        let ns = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        guard let rgb = ns.usingColorSpace(.genericRGB) else { return ns.cgColor }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: nil)

        // sRGB → linear light (remove gamma)
        func toLinear(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        // Per-hue perceptual boost so blue/violet match orange/yellow in perceived brightness.
        let boost = perceptualBoost(hue: hue, maxBoost: HDRConfig.perceptualMaxBoostHDR)
        let m = HDRConfig.trackEDRMultiplier * boost
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
