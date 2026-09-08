import CryptoKit
import Foundation

/// Metadata only; audio and resolved stream URLs are never stored here.
struct PlaylistsCache: Codable {
    var playlists: [SoundCloudPlaylist] = []
    var hasLoadedList = false
    var contents: [String: PlaylistContents] = [:]
}

struct PlaylistContents: Codable {
    var playlist: SoundCloudPlaylist
    var tracks: [SoundCloudTrack] = []
    var nextPageURL: URL?
    var hasLoadedPage = false

    var isComplete: Bool { hasLoadedPage && nextPageURL == nil }

    mutating func append(_ page: SoundCloudTrackPage) {
        var known = Set(tracks.map(\.urn))
        tracks.append(contentsOf: page.tracks.filter { known.insert($0.urn).inserted })
        nextPageURL = page.nextURL
        hasLoadedPage = true
    }
}

actor PlaylistsCacheStore {
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory
        .appending(path: "SoundClaude/Playlists", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func load(accountID: String) throws -> PlaylistsCache? {
        let url = fileURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PlaylistsCache.self, from: Data(contentsOf: url))
    }

    func save(_ cache: PlaylistsCache, accountID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: fileURL(accountID: accountID), options: .atomic)
    }

    private func fileURL(accountID: String) -> URL {
        let key = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: key + ".json")
    }
}
