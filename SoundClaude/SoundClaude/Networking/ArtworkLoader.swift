import Foundation
import CoreGraphics
import ImageIO

actor ArtworkLoader {
    enum Rendition: Sendable {
        case source
        case square500
        case square1080
        case original
    }

    private let client: SoundCloudClient
    private let cache = MemoryCache<NSURL, Data>(
        countLimit: 300,
        totalCostLimit: 32 * 1_024 * 1_024
    )
    private var requests: [URL: Task<Data, Error>] = [:]

    init(client: SoundCloudClient) {
        self.client = client
    }

    func accentColor(for url: URL) async throws -> ArtworkAccent? {
        let data = try await data(for: url)
        try Task.checkCancellation()
        return ArtworkAccent.extract(from: data)
    }

    func data(
        for url: URL,
        rendition: Rendition = .source
    ) async throws -> Data {
        let renditionURL = resolvedURL(for: rendition, sourceURL: url)

        do {
            return try await data(forResolvedURL: renditionURL)
        } catch {
            guard !Task.isCancelled, renditionURL != url else {
                throw error
            }
            // Some uploads have no accessible original. Try the website's
            // large rendition before falling back to the 100-pixel thumbnail.
            if case .original = rendition {
                return try await data(for: url, rendition: .square1080)
            }
            return try await data(forResolvedURL: url)
        }
    }

    private func data(forResolvedURL url: URL) async throws -> Data {
        if let cached = cache.value(forKey: url as NSURL) {
            return cached
        }
        if let request = requests[url] {
            return try await request.value
        }

        let client = client
        let request = Task {
            try await client.artworkData(from: url)
        }
        requests[url] = request

        do {
            let data = try await request.value
            requests[url] = nil
            cache.insert(data, forKey: url as NSURL, cost: data.count)
            return data
        } catch {
            requests[url] = nil
            throw error
        }
    }

    private func resolvedURL(
        for rendition: Rendition,
        sourceURL: URL
    ) -> URL {
        let renditionSuffix: String
        switch rendition {
        case .source:
            return sourceURL
        case .square500:
            renditionSuffix = "-t500x500"
        case .square1080:
            renditionSuffix = "-t1080x1080"
        case .original:
            renditionSuffix = "-original"
        }

        guard var components = URLComponents(
            url: sourceURL,
            resolvingAgainstBaseURL: false
        ) else {
            return sourceURL
        }

        let path = components.path as NSString
        let filename = path.lastPathComponent as NSString
        let extensionName = filename.pathExtension
        let name = filename.deletingPathExtension
        let thumbnailSuffix = "-large"

        guard !extensionName.isEmpty,
              name.hasSuffix(thumbnailSuffix) else {
            return sourceURL
        }

        let renditionName = name.dropLast(thumbnailSuffix.count)
            + renditionSuffix
        components.path = (path.deletingLastPathComponent as NSString)
            .appendingPathComponent(String(renditionName))
            + ".\(extensionName)"
        return components.url ?? sourceURL
    }
}

struct ArtworkAccent: Sendable {
    let red: Double
    let green: Double
    let blue: Double

    static func extract(from data: Data) -> ArtworkAccent? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: 32, height: 32,
                bitsPerComponent: 8, bytesPerRow: 32 * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        guard drawn else { return nil }

        // Group by hue so shades of a colorful detail compete together.
        // Keep neutral pixels separate so a gray background cannot drown it out.
        var buckets: [Int: (count: Double, red: Double, green: Double, blue: Double)] = [:]
        var pixelCount = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            let r = min(1, Double(pixels[index]) / 255 / alpha)
            let g = min(1, Double(pixels[index + 1]) / 255 / alpha)
            let b = min(1, Double(pixels[index + 2]) / 255 / alpha)
            let color = ArtworkAccent(red: r, green: g, blue: b)
            let hsv = color.hsv
            let isColorful = hsv.saturation >= 0.2 && hsv.brightness >= 0.15
                && max(r, g, b) - min(r, g, b) >= 0.06
            let key = isColorful ? Int((hsv.hue * 24).rounded()) % 24 : -1
            pixelCount += 1
            var bucket = buckets[key, default: (0, 0, 0, 0)]
            bucket.count += 1
            bucket.red += r
            bucket.green += g
            bucket.blue += b
            buckets[key] = bucket
        }
        var winner: ArtworkAccent?
        var bestScore = -1.0
        for key in buckets.keys.sorted() {
            // Ignore isolated colored pixels, but allow small accents in mostly gray art.
            guard key >= 0, let bucket = buckets[key],
                  bucket.count >= max(3, pixelCount * 0.005) else { continue }
            let color = ArtworkAccent(red: bucket.red / bucket.count,
                                      green: bucket.green / bucket.count,
                                      blue: bucket.blue / bucket.count)
            let hsv = color.hsv
            let score = sqrt(bucket.count) * (0.3 + hsv.saturation)
                * (0.4 + hsv.brightness)
            if score > bestScore {
                bestScore = score
                winner = Self.fromHSV(
                    hue: hsv.hue,
                    saturation: max(0.75, hsv.saturation),
                    brightness: max(0.85, hsv.brightness)
                )
            }
        }
        if let winner { return winner }
        guard let neutral = buckets[-1] else { return nil }
        // Push neutral artwork toward white so it stands out from unfilled bars.
        // Retain a small amount of the artwork's tint.
        return ArtworkAccent(red: 0.9 + 0.1 * neutral.red / neutral.count,
                             green: 0.9 + 0.1 * neutral.green / neutral.count,
                             blue: 0.9 + 0.1 * neutral.blue / neutral.count)
    }

    private var hsv: (hue: Double, saturation: Double, brightness: Double) {
        let maximum = max(red, green, blue)
        let delta = maximum - min(red, green, blue)
        guard delta > 0 else { return (0, 0, maximum) }
        let sector: Double
        if maximum == red {
            sector = (green - blue) / delta
        } else if maximum == green {
            sector = (blue - red) / delta + 2
        } else {
            sector = (red - green) / delta + 4
        }
        let hue = sector / 6
        return (hue < 0 ? hue + 1 : hue, delta / maximum, maximum)
    }

    private static func fromHSV(
        hue: Double, saturation: Double, brightness: Double
    ) -> ArtworkAccent {
        let sector = hue * 6
        let chroma = brightness * saturation
        let secondary = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let minimum = brightness - chroma
        let components: (Double, Double, Double)
        switch Int(sector) % 6 {
        case 0: components = (chroma, secondary, 0)
        case 1: components = (secondary, chroma, 0)
        case 2: components = (0, chroma, secondary)
        case 3: components = (0, secondary, chroma)
        case 4: components = (secondary, 0, chroma)
        default: components = (chroma, 0, secondary)
        }
        return ArtworkAccent(red: components.0 + minimum,
                             green: components.1 + minimum,
                             blue: components.2 + minimum)
    }

    static func trackBackground(isDark: Bool) -> ArtworkAccent {
        let gray = isDark ? 0.12 : 0.94
        return ArtworkAccent(red: gray, green: gray, blue: gray)
    }

    func contrasted(isDark: Bool, increasedContrast: Bool) -> ArtworkAccent {
        let background = Self.trackBackground(isDark: isDark)
        let target = increasedContrast ? 4.5 : 3.0
        // Mix toward white in dark mode or black in light mode only as needed.
        for step in 0...100 {
            let amount = Double(step) / 100
            let end = isDark ? 1.0 : 0.0
            let candidate = ArtworkAccent(
                red: red * (1 - amount) + end * amount,
                green: green * (1 - amount) + end * amount,
                blue: blue * (1 - amount) + end * amount
            )
            let ratio = (max(candidate.luminance, background.luminance) + 0.05)
                / (min(candidate.luminance, background.luminance) + 0.05)
            if ratio >= target { return candidate }
        }
        return isDark ? ArtworkAccent(red: 1, green: 1, blue: 1)
            : ArtworkAccent(red: 0, green: 0, blue: 0)
    }

    private var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
