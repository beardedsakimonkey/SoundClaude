import Foundation

actor ArtworkLoader {
    private let client: SoundCloudClient
    private let cache = MemoryCache<NSURL, Data>(
        countLimit: 300,
        totalCostLimit: 32 * 1_024 * 1_024
    )
    private var requests: [URL: Task<Data, Error>] = [:]

    init(client: SoundCloudClient) {
        self.client = client
    }

    func data(for url: URL) async throws -> Data {
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
}
