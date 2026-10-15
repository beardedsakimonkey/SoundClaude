import CryptoKit
import Foundation

/// Metadata only; audio and resolved stream URLs are never stored here.
struct PlaylistsCache: Codable {
    var playlists: [SoundCloudPlaylist] = []
    var hasLoadedList = false
    var contents: [String: PlaylistContents] = [:]
    var artworkURLs: [String: URL]?
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
        var artworkURLs: [String: URL]?
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
        return PlaylistsCache(playlists: sidebar.playlists, hasLoadedList: sidebar.hasLoadedList, artworkURLs: sidebar.artworkURLs)
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
        try prune(accountID: accountID)
    }

    /// Preserve library contents and only the 20 most recently written external playlists.
    /// Migrate library entries before removing the unbounded legacy snapshot.
    func prune(accountID: String) throws {
        guard let sidebar = try loadForLaunch(accountID: accountID) else { return }
        let legacy = fileURL(accountID: accountID)
        if FileManager.default.fileExists(atPath: legacy.path) {
            for playlist in sidebar.playlists {
                _ = try loadContents(urn: playlist.urn, accountID: accountID)
            }
            try saveSidebar(sidebar, accountID: accountID)
            try FileManager.default.removeItem(at: legacy)
        }
        let protected = Set(sidebar.playlists.map { contentsURL(urn: $0.urn, accountID: accountID).lastPathComponent })
        let folder = contentsDirectory(accountID: accountID)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter { $0.pathExtension == "json" && !protected.contains($0.lastPathComponent) }
        var dated: [(URL, Date)] = []
        for url in files {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            dated.append((url, values.contentModificationDate ?? Date.distantPast))
        }
        dated.sort { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
        for (url, _) in dated.dropFirst(20) { try FileManager.default.removeItem(at: url) }
    }

    func removeContents(urn: String, accountID: String) throws {
        // A tombstone also hides an entry in the legacy cache.
        try saveContents(nil, urn: urn, accountID: accountID)
    }

    private func saveContents(_ contents: PlaylistContents?, urn: String, accountID: String) throws {
        try FileManager.default.createDirectory(at: contentsDirectory(accountID: accountID), withIntermediateDirectories: true)
        let url = contentsURL(urn: urn, accountID: accountID)
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONDecoder().decode(ContentFile.self, from: data),
           existing.contents == contents { return }
        try JSONEncoder().encode(ContentFile(urn: urn, contents: contents))
            .write(to: url, options: .atomic)
    }

    private func contentsDirectory(accountID: String) -> URL {
        fileURL(accountID: accountID).deletingPathExtension().appendingPathExtension("contents")
    }

    private func contentsURL(urn: String, accountID: String) -> URL {
        let key = SHA256.hash(data: Data(urn.utf8)).map { String(format: "%02x", $0) }.joined()
        return contentsDirectory(accountID: accountID).appending(path: key + ".json")
    }

    private func saveSidebar(_ cache: PlaylistsCache, accountID: String) throws {
        var artworkURLs = cache.artworkURLs ?? [:]
        for playlist in cache.playlists {
            if let contents = cache.contents[playlist.urn] {
                artworkURLs[playlist.urn] = contents.playlist.artworkURL
                    ?? contents.tracks.first(where: { $0.displayArtworkURL != nil })?.displayArtworkURL
            }
        }
        let libraryURNs = Set(cache.playlists.map(\.urn))
        let sidebar = SidebarCache(
            playlists: cache.playlists, hasLoadedList: cache.hasLoadedList,
            artworkURLs: artworkURLs.filter { libraryURNs.contains($0.key) }
        )
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
