import Foundation

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
