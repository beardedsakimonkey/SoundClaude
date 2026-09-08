import CryptoKit
import Foundation

/// Activity metadata only; no audio or resolved stream URLs.
struct FeedCache: Codable {
    var items: [SoundCloudFeedItem] = []
    var nextPageURL: URL?
    var loadedPageURLs: Set<URL> = []
    var hasLoadedPage = false

    mutating func append(_ page: SoundCloudFeedPage, requestedURL: URL?) throws {
        if let next = page.nextURL,
           next == requestedURL || loadedPageURLs.contains(next) {
            throw SoundCloudError.invalidData
        }
        var known = Set(items.map(\.id))
        items.append(contentsOf: page.items.filter { known.insert($0.id).inserted })
        if let requestedURL { loadedPageURLs.insert(requestedURL) }
        nextPageURL = page.nextURL
        hasLoadedPage = true
    }

    /// Keep the older cached tail once fresh pages reach a known activity.
    /// An end-of-feed response replaces the whole snapshot, including removals.
    mutating func mergeTail(from baseline: FeedCache) -> Bool {
        guard nextPageURL != nil else { return true }
        guard let last = items.last,
              let index = baseline.items.firstIndex(where: { $0.id == last.id }) else { return false }
        var known = Set(items.map(\.id))
        items.append(contentsOf: baseline.items.suffix(from: index + 1).filter { known.insert($0.id).inserted })
        nextPageURL = baseline.nextPageURL
        loadedPageURLs = baseline.loadedPageURLs
        return true
    }
}

actor FeedCacheStore {
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory
        .appending(path: "SoundClaude/Feed", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func load(accountID: String) throws -> FeedCache? {
        let url = fileURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(FeedCache.self, from: Data(contentsOf: url))
    }

    func save(_ cache: FeedCache, accountID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: fileURL(accountID: accountID), options: .atomic)
    }

    private func fileURL(accountID: String) -> URL {
        let key = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: key + ".json")
    }
}
