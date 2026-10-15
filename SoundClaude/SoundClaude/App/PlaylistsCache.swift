import CryptoKit
import Foundation

/// Metadata only; audio and resolved stream URLs are never stored here.
struct PlaylistsCache: Codable {
    var playlists: [SoundCloudPlaylist] = []
    var hasLoadedList = false
    var contents: [String: PlaylistContents] = [:]
}

struct PlaylistContents: Codable, Equatable {
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
    private struct SidebarCache: Codable {
        var playlists: [SoundCloudPlaylist]
        var hasLoadedList: Bool
    }

    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory
        .appending(path: "SoundClaude/Playlists", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func load(accountID: String) throws -> PlaylistsCache? {
        let url = fileURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let cache = try JSONDecoder().decode(PlaylistsCache.self, from: Data(contentsOf: url))
        try? saveSidebar(cache, accountID: accountID)
        return cache
    }

    // Only decode the list before the first frame, never cached track details.
    nonisolated func loadForLaunch(accountID: String) throws -> PlaylistsCache? {
        let sidebarURL = fileURL(accountID: accountID, suffix: "-sidebar")
        // Older installations acquire the small snapshot during background restoration.
        let url = FileManager.default.fileExists(atPath: sidebarURL.path)
            ? sidebarURL : fileURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let sidebar = try JSONDecoder().decode(SidebarCache.self, from: Data(contentsOf: url))
        return PlaylistsCache(playlists: sidebar.playlists, hasLoadedList: sidebar.hasLoadedList)
    }

    func save(_ cache: PlaylistsCache, accountID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: fileURL(accountID: accountID), options: .atomic)
        try saveSidebar(cache, accountID: accountID)
    }

    private func saveSidebar(_ cache: PlaylistsCache, accountID: String) throws {
        let sidebar = SidebarCache(playlists: cache.playlists, hasLoadedList: cache.hasLoadedList)
        try JSONEncoder().encode(sidebar).write(
            to: fileURL(accountID: accountID, suffix: "-sidebar"), options: .atomic
        )
    }

    nonisolated private func fileURL(accountID: String, suffix: String = "") -> URL {
        let key = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: key + suffix + ".json")
    }
}
