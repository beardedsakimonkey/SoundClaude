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

        let invalidLoader = ArtworkLoader(client: SoundCloudClient(payload: Data([0, 1, 2])))
        let invalid = try await invalidLoader.image(for: url)
        precondition(invalid == nil && invalidLoader.cachedImage(for: url) == nil)
        print("Artwork cache reuse, rendition isolation, downsampling, and invalid image tests passed")
    }
}
