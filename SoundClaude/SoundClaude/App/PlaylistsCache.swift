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

    private struct ContentFile: Codable {
        var urn: String
        var contents: PlaylistContents?
    }

    // Decode just the requested entry from the old combined cache. JSONDecoder
    // skips the other track objects. New writes use one file per playlist.
    private struct LegacyContents: Decodable {
        let contents: PlaylistContents?
        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: Key.self)
            let entries = try root.nestedContainer(keyedBy: Key.self, forKey: Key(stringValue: "contents"))
            let urn = decoder.userInfo[.playlistURN] as! String
            contents = try entries.decodeIfPresent(PlaylistContents.self, forKey: Key(stringValue: urn))
        }
    }

    func loadContents(urn: String, accountID: String) throws -> PlaylistContents? {
        let url = contentsURL(urn: urn, accountID: accountID)
        if FileManager.default.fileExists(atPath: url.path) {
            return try LaunchMetrics.measure("Playlist contents decode") {
                try JSONDecoder().decode(ContentFile.self, from: Data(contentsOf: url)).contents
            }
        }
        let legacy = fileURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.userInfo[.playlistURN] = urn
        let contents = try LaunchMetrics.measure("Legacy playlist contents decode") {
            try decoder.decode(LegacyContents.self, from: Data(contentsOf: legacy)).contents
        }
        if let contents { try saveContents(contents, urn: urn, accountID: accountID) }
        return contents
    }

    // Full snapshot for diagnostics and regression tests, never used at launch.
    func load(accountID: String) throws -> PlaylistsCache? {
        var cache = try loadForLaunch(accountID: accountID)
        let legacy = fileURL(accountID: accountID)
        if FileManager.default.fileExists(atPath: legacy.path),
           let old = try? JSONDecoder().decode(PlaylistsCache.self, from: Data(contentsOf: legacy)) {
            if cache == nil { cache = old }
            else { cache?.contents = old.contents }
        }
        let folder = contentsDirectory(accountID: accountID)
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            let entry = try JSONDecoder().decode(ContentFile.self, from: Data(contentsOf: url))
            cache?.contents[entry.urn] = entry.contents
        }
        return cache
    }

    // Only decode the list before the first frame, never cached track details.
    nonisolated func loadForLaunch(accountID: String) throws -> PlaylistsCache? {
        let sidebarURL = fileURL(accountID: accountID, suffix: "-sidebar")
        // Older installations acquire the small snapshot on the next successful save.
        let url = FileManager.default.fileExists(atPath: sidebarURL.path)
            ? sidebarURL : fileURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let sidebar = try JSONDecoder().decode(SidebarCache.self, from: Data(contentsOf: url))
        return PlaylistsCache(playlists: sidebar.playlists, hasLoadedList: sidebar.hasLoadedList)
    }

    func save(_ cache: PlaylistsCache, accountID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = try? loadForLaunch(accountID: accountID)
        let current = Set(cache.playlists.map(\.urn))
        if cache.hasLoadedList {
            for playlist in previous?.playlists ?? [] where !current.contains(playlist.urn) {
                try removeContents(urn: playlist.urn, accountID: accountID)
            }
        }
        for (urn, contents) in cache.contents {
            try saveContents(contents, urn: urn, accountID: accountID)
        }
        try saveSidebar(cache, accountID: accountID)
    }

    func removeContents(urn: String, accountID: String) throws {
        // A tombstone also hides an entry in the legacy cache.
        try saveContents(nil, urn: urn, accountID: accountID)
    }

    private func saveContents(_ contents: PlaylistContents?, urn: String, accountID: String) throws {
        try FileManager.default.createDirectory(at: contentsDirectory(accountID: accountID), withIntermediateDirectories: true)
        try JSONEncoder().encode(ContentFile(urn: urn, contents: contents))
            .write(to: contentsURL(urn: urn, accountID: accountID), options: .atomic)
    }

    private func contentsDirectory(accountID: String) -> URL {
        fileURL(accountID: accountID).deletingPathExtension().appendingPathExtension("contents")
    }

    private func contentsURL(urn: String, accountID: String) -> URL {
        let key = SHA256.hash(data: Data(urn.utf8)).map { String(format: "%02x", $0) }.joined()
        return contentsDirectory(accountID: accountID).appending(path: key + ".json")
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

private extension CodingUserInfoKey {
    static let playlistURN = CodingUserInfoKey(rawValue: "playlistURN")!
}
