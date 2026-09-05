import Foundation
import CoreGraphics
import ImageIO

actor ArtworkLoader {
    enum Rendition: Sendable {
        case source
        case square500
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

        // Group similar colors, favoring common saturated colors over gray borders.
        var buckets: [Int: (count: Double, red: Double, green: Double, blue: Double)] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            let r = min(1, Double(pixels[index]) / 255 / alpha)
            let g = min(1, Double(pixels[index + 1]) / 255 / alpha)
            let b = min(1, Double(pixels[index + 2]) / 255 / alpha)
            let key = (Int(r * 15) << 8) | (Int(g * 15) << 4) | Int(b * 15)
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
            guard let bucket = buckets[key] else { continue }
            let color = ArtworkAccent(red: bucket.red / bucket.count,
                                      green: bucket.green / bucket.count,
                                      blue: bucket.blue / bucket.count)
            let saturation = max(color.red, color.green, color.blue)
                - min(color.red, color.green, color.blue)
            let score = bucket.count * (0.2 + saturation)
            if score > bestScore {
                bestScore = score
                winner = color
            }
        }
        return winner
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
