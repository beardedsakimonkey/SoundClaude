import AppKit
import ImageIO
import UniformTypeIdentifiers

// Standalone loader tests use generated images and no network or credentials.
actor SoundCloudClient {
    let payload: Data
    private(set) var requests = 0

    init(payload: Data) { self.payload = payload }

    func artworkData(from url: URL) async throws -> Data {
        requests += 1
        await Task.yield()
        return payload
    }
}

@main
struct ArtworkCacheTests {
    @MainActor
    static func main() async throws {
        let context = CGContext(
            data: nil, width: 2000, height: 1000, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let client = SoundCloudClient(payload: encoded as Data)
        let loader = ArtworkLoader(client: client)
        let url = URL(string: "https://i1.sndcdn.com/example-large.png")!
        precondition(loader.cachedImage(for: url, rendition: .square500) == nil)

        async let artwork = loader.image(for: url, rendition: .square500)
        async let reflection = loader.image(for: url, rendition: .square500)
        let (first, second) = try await (artwork, reflection)
        let image = first!
        precondition(image === second, "Artwork and reflection must share decoded pixels")
        precondition(loader.cachedImage(for: url, rendition: .square500) === image,
                     "A returning view must synchronously retrieve the same image")
        let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(bitmap.width == 500 && bitmap.height == 250,
                     "Large images must be downsampled and preserve aspect ratio")
        precondition(bitmap.bytesPerRow * bitmap.height <= 1_024 * 1_024)
        let revisited = try await loader.image(for: url, rendition: .square500)
        precondition(revisited === image)
        let count = await client.requests
        precondition(count == 1, "Revisits and concurrent views must reuse the request")
        precondition(loader.cachedImage(for: url) == nil, "Renditions must have separate cache keys")
        let backdrop = try await loader.image(for: url)
        precondition(loader.cachedImage(for: url) === backdrop)
        precondition(loader.cachedImage(for: url, rendition: .square500) === image)

        // Source prefetch prepares both the backdrop and its accent without
        // another request when the detail view and footer arrive together.
        async let firstAccent = loader.accentColor(for: url)
        async let secondAccent = loader.accentColor(for: url)
        let (accent, sharedAccent) = try await (firstAccent, secondAccent)
        precondition(accent != nil && accent?.red == sharedAccent?.red
                     && accent?.green == sharedAccent?.green && accent?.blue == sharedAccent?.blue)
        let sourceRequests = await client.requests
        precondition(sourceRequests == 2, "Backdrop and accents share the source request")

        // Visualizer pixels are decoded off the UI actor and bounded even if
        // the server returns a larger source than the requested rendition.
        async let visualizer = loader.bitmap(for: url, rendition: .square1080)
        async let sharedVisualizer = loader.bitmap(for: url, rendition: .square1080)
        let (large, sharedLarge) = try await (visualizer, sharedVisualizer)
        precondition(large === sharedLarge, "Concurrent visualizers must share decoded pixels")
        precondition(large?.width == 1080 && large?.height == 540)
        let small = try await loader.bitmap(for: url, rendition: .square1080, maxPixelSize: 500)
        precondition(small?.width == 500 && small?.height == 250)
        precondition(small !== large, "Decode sizes must have separate cache entries")
        let revisitedLarge = try await loader.bitmap(for: url, rendition: .square1080)
        precondition(revisitedLarge === large)

        let invalidLoader = ArtworkLoader(client: SoundCloudClient(payload: Data([0, 1, 2])))
        let invalid = try await invalidLoader.image(for: url)
        precondition(invalid == nil && invalidLoader.cachedImage(for: url) == nil)
        print("Artwork cache reuse, rendition isolation, downsampling, and invalid image tests passed")
    }
}
