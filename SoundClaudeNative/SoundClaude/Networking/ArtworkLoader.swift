import Foundation

actor ArtworkLoader {
    private let client: SoundCloudClient
    private let cache = NSCache<NSURL, NSData>()
    private var requests: [URL: Task<Data, Error>] = [:]

    init(client: SoundCloudClient) {
        self.client = client
        cache.countLimit = 300
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    func data(for url: URL) async throws -> Data {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached as Data
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
            cache.setObject(
                data as NSData,
                forKey: url as NSURL,
                cost: data.count
            )
            return data
        } catch {
            requests[url] = nil
            throw error
        }
    }
}
