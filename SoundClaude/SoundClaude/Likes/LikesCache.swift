import CryptoKit
import Foundation

/// Metadata only. Stream URLs and audio are resolved when a track is played.
struct LikesCache: Codable {
    var tracks: [SoundCloudTrack] = []
    var nextPageURL: URL?
    var hasLoadedPage = false

    /// Stop at a cached page boundary and retain the older library. A re-like
    /// can move a cached track to the top, so overlap alone does not prove that
    /// missing cached entries were removed. Only a complete response does.
    mutating func mergeHead(_ head: [SoundCloudTrack], nextURL: URL?, baseline: LikesCache) -> Bool {
        let oldURNs = Set(baseline.tracks.map(\.urn))
        let reachedCache = head.last.map { oldURNs.contains($0.urn) } ?? false
        guard reachedCache || nextURL == nil else { return false }
        var known = Set<String>()
        let merged = head + (nextURL == nil ? [] : baseline.tracks)
        tracks = merged.filter { known.insert($0.urn).inserted }
        nextPageURL = nextURL == nil ? nil : baseline.nextPageURL
        hasLoadedPage = true
        return true
    }

    mutating func append(_ page: SoundCloudTrackPage) {
        var known = Set(tracks.map(\.urn))
        tracks.append(contentsOf: page.tracks.filter { known.insert($0.urn).inserted })
        nextPageURL = page.nextURL
        hasLoadedPage = true
    }
}

actor LikesCacheStore {
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory
        .appending(path: "SoundClaude/Likes", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func load(accountID: String) throws -> LikesCache? {
        let url = fileURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(LikesCache.self, from: Data(contentsOf: url))
    }

    func save(_ cache: LikesCache, accountID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: fileURL(accountID: accountID), options: .atomic)
    }

    private func fileURL(accountID: String) -> URL {
        let key = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: key + ".json")
    }
}
