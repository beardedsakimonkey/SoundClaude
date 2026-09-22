import AppKit

// Each view retains a small palette across animation frames. Key by resolved
// CGColor and appearance so color and highlight changes get fresh shading.
final class WaveformShadingCache {
    private var entries: [(color: CGColor, isDark: Bool, image: CGImage)] = []

    func image(for color: CGColor, isDark: Bool) -> CGImage? {
        if let entry = entries.first(where: { $0.color == color && $0.isDark == isDark }) {
            return entry.image
        }
        guard let gradient = makeGradient(for: color, isDark: isDark),
              let context = CGContext(
                data: nil, width: 1, height: 256,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        // Match the bottom-up bar coordinates. The strip has enough samples
        // for Retina detail bars and is independent of their animated heights.
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 256),
            end: .zero,
            options: []
        )
        guard let image = context.makeImage() else { return nil }
        if entries.count == 8 {
            entries.removeFirst()
        }
        entries.append((color, isDark, image))
        return image
    }

    private func makeGradient(for color: CGColor, isDark: Bool) -> CGGradient? {
        let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        guard let components = color.converted(
            to: colorSpace, intent: .relativeColorimetric, options: nil
        )?.components, components.count == 4 else { return nil }

        let base = WaveformOKLab(linearRGB: SIMD3(
            Double(components[0]), Double(components[1]), Double(components[2])
        )).value
        // Build the shaded stops and interpolate them in OKLab, including
        // the white crest. Keep alpha constant throughout the surface.
        let profile: [(location: CGFloat, brightness: CGFloat, highlight: CGFloat)] = [
            (0,    0.98, 0.08),
            (0.08, 1,    0.30),
            (0.24, 0.98, 0.12),
            (1,    0.87, 0.03)
        ]
        let stops = profile.map { stop in
            // Keep a subtle crest on light backgrounds without a white stripe.
            let highlight = stop.highlight * (isDark ? 1 : 0.25)
            return base * Double(stop.brightness * (1 - highlight))
                + SIMD3<Double>(Double(highlight), 0, 0)
        }
        // Core Graphics interpolates in RGB. Sample the OKLab curve densely
        // and include the exact profile stops to preserve each crest.
        let locations = Array(Set((0...64).map { CGFloat($0) / 64 }
            + profile.map(\.location))).sorted()
        let colors = locations.map { fraction in
            let upperIndex = profile.firstIndex { $0.location > fraction }
                ?? (profile.count - 1)
            let lower = profile[upperIndex - 1]
            let upper = profile[upperIndex]
            let t = (fraction - lower.location) / (upper.location - lower.location)
            let eased = t * t * (3 - 2 * t)
            let lab = stops[upperIndex - 1]
                + (stops[upperIndex] - stops[upperIndex - 1]) * Double(eased)
            let rgb = WaveformOKLab(value: lab).linearRGB
            return CGColor(colorSpace: colorSpace, components: [
                CGFloat(min(max(rgb.x, 0), 1)),
                CGFloat(min(max(rgb.y, 0), 1)),
                CGFloat(min(max(rgb.z, 0), 1)),
                components[3]
            ])!
        }
        return CGGradient(
            colorsSpace: colorSpace, colors: colors as CFArray, locations: locations
        )

    }
}

// OKLab conversion matrices:
// https://bottosson.github.io/posts/oklab/#converting-from-linear-srgb-to-oklab
private struct WaveformOKLab {
    let value: SIMD3<Double>

    init(value: SIMD3<Double>) {
        self.value = value
    }

    init(linearRGB rgb: SIMD3<Double>) {
        let l = cbrt(0.4122214708 * rgb.x + 0.5363325363 * rgb.y + 0.0514459929 * rgb.z)
        let m = cbrt(0.2119034982 * rgb.x + 0.6806995451 * rgb.y + 0.1073969566 * rgb.z)
        let s = cbrt(0.0883024619 * rgb.x + 0.2817188376 * rgb.y + 0.6299787005 * rgb.z)
        value = SIMD3(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    var linearRGB: SIMD3<Double> {
        let roots = SIMD3(
            value.x + 0.3963377774 * value.y + 0.2158037573 * value.z,
            value.x - 0.1055613458 * value.y - 0.0638541728 * value.z,
            value.x - 0.0894841775 * value.y - 1.2914855480 * value.z
        )
        let cubes = roots * roots * roots
        return SIMD3(
            4.0767416621 * cubes.x - 3.3077115913 * cubes.y + 0.2309699292 * cubes.z,
            -1.2684380046 * cubes.x + 2.6097574011 * cubes.y - 0.3413193965 * cubes.z,
            -0.0041960863 * cubes.x - 0.7034186147 * cubes.y + 1.7076147010 * cubes.z
        )
    }
}
