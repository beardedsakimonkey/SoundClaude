import AppKit
import ImageIO
import UniformTypeIdentifiers

// Standalone loader tests use generated images and no network or credentials.
actor SoundCloudClient {
    let payload: Data
    private(set) var requests = 0
    private(set) var requestedURLs: [URL] = []
    private var holdsRequests = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func hold() { holdsRequests = true }
    func release() {
        holdsRequests = false
        let continuations = waiting
        waiting.removeAll()
        continuations.forEach { $0.resume() }
    }

    init(payload: Data) { self.payload = payload }

    func artworkData(from url: URL) async throws -> Data {
        requests += 1
        requestedURLs.append(url)
        if holdsRequests {
            await withCheckedContinuation { waiting.append($0) }
        }
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

        // Replacing the scroll window drops queued work without starting
        // more than three loads, and prefetch warms the exact display cache.
        let prefetchClient = SoundCloudClient(payload: encoded as Data)
        let prefetchLoader = ArtworkLoader(client: prefetchClient)
        let prefetcher = TrackArtworkPrefetcher()
        let urls = (0..<8).map { URL(string: "https://i1.sndcdn.com/prefetch-\($0).png")! }
        await prefetchClient.hold()
        prefetcher.update(urls: urls + urls, visibleURLs: [], loader: prefetchLoader)
        while await prefetchClient.requests < 3 { await Task.yield() }
        let initialCount = await prefetchClient.requests
        precondition(initialCount == 3, "Prefetch must limit concurrent requests")
        prefetcher.update(urls: [urls[7]], visibleURLs: [], loader: prefetchLoader)
        await prefetchClient.release()
        while prefetchLoader.cachedImage(for: urls[7], rendition: .square500) == nil {
            await Task.yield()
        }
        let fetchedURLs = await prefetchClient.requestedURLs
        precondition(Set(fetchedURLs) == Set(Array(urls.prefix(3)) + [urls[7]]),
                     "A new window must discard stale queued artwork")
        precondition(fetchedURLs.count == 4, "Duplicate artwork must share prefetch work")
        prefetcher.update(urls: [], visibleURLs: [], loader: prefetchLoader)

        // Visible requests gate speculative work, including after a jump.
        let gatedClient = SoundCloudClient(payload: encoded as Data)
        let gatedLoader = ArtworkLoader(client: gatedClient)
        let gated = TrackArtworkPrefetcher()
        gated.update(urls: [urls[2]], visibleURLs: [urls[0], urls[1]], loader: gatedLoader)
        gated.artworkDidFinish(url: urls[0], loader: gatedLoader)
        for _ in 0..<20 { await Task.yield() }
        let beforeVisibleFinished = await gatedClient.requests
        precondition(beforeVisibleFinished == 0, "All visible artwork must finish before prefetch")
        await gatedClient.hold()
        gated.artworkDidFinish(url: urls[1], loader: gatedLoader)
        while await gatedClient.requests < 1 { await Task.yield() }
        gated.update(urls: [urls[4]], visibleURLs: [urls[3]], loader: gatedLoader)
        await gatedClient.release()
        while gatedLoader.cachedImage(for: urls[2], rendition: .square500) == nil {
            await Task.yield()
        }
        gated.artworkDidFinish(url: urls[1], loader: gatedLoader)
        for _ in 0..<20 { await Task.yield() }
        let afterJump = await gatedClient.requests
        precondition(afterJump == 1, "Old completions must not unblock a new viewport")
        // Completion does not require a cached image: errors must not stall the queue.
        gated.artworkDidFinish(url: urls[3], loader: gatedLoader)
        while gatedLoader.cachedImage(for: urls[4], rendition: .square500) == nil {
            await Task.yield()
        }
        // Cached visible artwork needs no completion callback to start prefetch.
        gated.update(urls: [urls[5]], visibleURLs: [urls[4]], loader: gatedLoader)
        while gatedLoader.cachedImage(for: urls[5], rendition: .square500) == nil {
            await Task.yield()
        }
        gated.update(urls: [], visibleURLs: [], loader: gatedLoader)

        let toggleClient = SoundCloudClient(payload: encoded as Data)
        let toggleLoader = ArtworkLoader(client: toggleClient)
        let toggled = TrackArtworkPrefetcher()
        await toggleClient.hold()
        toggled.update(urls: urls, visibleURLs: [], loader: toggleLoader)
        while await toggleClient.requests < 3 { await Task.yield() }
        toggled.update(urls: urls, visibleURLs: [], loader: toggleLoader, isEnabled: false)
        await toggleClient.release()
        for url in urls.prefix(3) {
            while toggleLoader.cachedImage(for: url, rendition: .square500) == nil {
                await Task.yield()
            }
        }
        for _ in 0..<20 { await Task.yield() }
        let disabledRequests = await toggleClient.requests
        precondition(disabledRequests == 3, "Disabling prefetch must stop queued work")
        toggled.update(urls: [urls[7]], visibleURLs: [], loader: toggleLoader)
        while toggleLoader.cachedImage(for: urls[7], rendition: .square500) == nil {
            await Task.yield()
        }
        let enabledRequests = await toggleClient.requests
        precondition(enabledRequests == 4, "Enabling prefetch must resume the current window")

        // Lists must warm all eight source images, without loading grid renditions.
        let listURLs = (0..<8).map { URL(string: "https://i1.sndcdn.com/list-\($0)-large.png")! }
        let listClient = SoundCloudClient(payload: encoded as Data)
        let listLoader = ArtworkLoader(client: listClient)
        let listPrefetcher = TrackArtworkPrefetcher(rendition: .source)
        let visibleURL = URL(string: "https://i1.sndcdn.com/list-visible.png")!
        listPrefetcher.update(urls: listURLs, visibleURLs: [visibleURL], loader: listLoader)
        for _ in 0..<20 { await Task.yield() }
        let beforeListVisibleFinished = await listClient.requests
        precondition(beforeListVisibleFinished == 0)
        listPrefetcher.artworkDidFinish(url: visibleURL, loader: listLoader)
        for url in listURLs {
            while listLoader.cachedImage(for: url, rendition: .source) == nil {
                await Task.yield()
            }
            precondition(listLoader.cachedImage(for: url, rendition: .square500) == nil,
                         "List prefetch must use the row's source rendition")
            _ = try await listLoader.image(for: url)
        }
        let listRequests = await listClient.requests
        precondition(listRequests == 8, "Eight prefetched rows must reuse their cached artwork")
        listPrefetcher.update(urls: [], visibleURLs: [], loader: listLoader)

        // Rapid row changes must replace the window before speculative work starts.
        let scrollClient = SoundCloudClient(payload: encoded as Data)
        let scrollLoader = ArtworkLoader(client: scrollClient)
        let scroll = TrackListArtworkPrefetcher()
        let scrollIDs = (0..<20).map(String.init)
        let scrollURLs = (0..<20).map { URL(string: "https://i1.sndcdn.com/scroll-\($0)-large.png")! }
        scroll.configure(ids: scrollIDs, urls: scrollURLs, loader: scrollLoader, isEnabled: true)
        scroll.setVisible("0", isVisible: true, loader: scrollLoader)
        scroll.prefetcher.artworkDidFinish(url: scrollURLs[0], loader: scrollLoader)
        scroll.setVisible("0", isVisible: false, loader: scrollLoader)
        scroll.setVisible("10", isVisible: true, loader: scrollLoader)
        scroll.prefetcher.artworkDidFinish(url: scrollURLs[10], loader: scrollLoader)
        let duringScroll = await scrollClient.requests
        precondition(duringScroll == 0, "Visibility updates must not immediately start loads")
        for url in scrollURLs[11...18] {
            while scrollLoader.cachedImage(for: url) == nil { await Task.yield() }
        }
        let scrolledURLs = await scrollClient.requestedURLs
        precondition(Set(scrolledURLs) == Set(scrollURLs[11...18]),
                     "Only the latest eight-row window should load after a rapid jump")
        scroll.setVisible("10", isVisible: false, loader: scrollLoader)
        scroll.setVisible("0", isVisible: true, loader: scrollLoader)
        scroll.stop(loader: scrollLoader)
        try await Task.sleep(for: .milliseconds(100))
        let stoppedRequests = await scrollClient.requests
        precondition(stoppedRequests == 8, "Leaving the list must cancel its delayed update")

        let invalidLoader = ArtworkLoader(client: SoundCloudClient(payload: Data([0, 1, 2])))
        let invalid = try await invalidLoader.image(for: url)
        precondition(invalid == nil && invalidLoader.cachedImage(for: url) == nil)
        print("Artwork cache reuse, rendition isolation, downsampling, and invalid image tests passed")
    }
}
