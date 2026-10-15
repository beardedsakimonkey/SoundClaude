import Foundation
import Observation
import os

@MainActor
final class AuthController {
    enum State { case signedIn(SoundCloudUser), signedOut }
    var state: State = .signedIn(user)
    func validAccessToken() async throws -> String { "test" }
}

@MainActor
final class SoundCloudClient {
    var addedTrackURNs: [String] = []
    var failAddition = false
    func addTrackToPlaylist(trackURN: String, playlistURN: String, accessToken: String) async throws {
        if failAddition { throw SoundCloudError.invalidData }
        addedTrackURNs.append(trackURN)
    }
    var removedTrackURNs: [String] = []
    var failRemoval = false
    func removeTrackFromPlaylist(trackURN: String, playlistURN: String, accessToken: String) async throws {
        if failRemoval { throw SoundCloudError.invalidData }
        removedTrackURNs.append(trackURN)
    }
    var failDeletion = false
    var deletedURNs: [String] = []
    func deletePlaylist(urn: String, accessToken: String) async throws {
        if failDeletion { throw SoundCloudError.invalidData }
        deletedURNs.append(urn)
    }
    var failCreation = false
    func createPlaylist(title: String, description: String, isPrivate: Bool, artwork: PlaylistArtwork? = nil, accessToken: String) async throws -> SoundCloudPlaylist {
        if failCreation { throw SoundCloudError.invalidData }
        return makePlaylist(99, isPrivate: isPrivate)
    }
    var failUpdate = false
    func updatePlaylist(urn: String, title: String, description: String, isPrivate: Bool,
                        accessToken: String) async throws -> SoundCloudPlaylist {
        if failUpdate { throw SoundCloudError.invalidData }
        return SoundCloudPlaylist(urn: urn, title: title, owner: user, artworkURL: nil,
                                  permalinkURL: user.permalinkURL, description: description,
                                  trackCount: 3, durationMilliseconds: 3000, isPrivate: isPrivate)
    }
    var listRequests: [URL?] = []
    var trackRequests: [URL?] = []
    var fetchList: (URL?) async throws -> SoundCloudPlaylistPage = { _ in
        SoundCloudPlaylistPage(playlists: [], nextURL: nil)
    }
    var fetchTracks: (URL?) async throws -> SoundCloudTrackPage = { _ in
        SoundCloudTrackPage(tracks: [], nextURL: nil)
    }
    var stationRequests: [String] = []
    var playlistRequests: [String] = []
    func station(urn: String, accessToken: String) async throws -> SoundCloudStation {
        stationRequests.append(urn)
        return SoundCloudStation(title: "Daily mix", description: "Your mix",
            permalinkURL: URL(string: "https://soundcloud.com/discover/sets/daily-mix:1"),
            lastUpdated: "2026-10-05T12:00:00Z", trackCount: 2, tracks: [track(4), track(5)])
    }
    var details = makePlaylist(1)
    var fetchLikes: (URL?) async throws -> SoundCloudPlaylistPage = { _ in
        SoundCloudPlaylistPage(playlists: [], nextURL: nil)
    }
    var likeWrites: [Bool] = []
    var failLikeWrite = false
    func likedPlaylists(accessToken: String, pageURL: URL?) async throws -> SoundCloudPlaylistPage {
        try await fetchLikes(pageURL)
    }
    func setPlaylistLiked(urn: String, isLiked: Bool, accessToken: String) async throws {
        likeWrites.append(isLiked)
        if failLikeWrite { throw SoundCloudError.invalidData }
    }
    func playlists(accessToken: String, pageURL: URL?) async throws -> SoundCloudPlaylistPage {
        listRequests.append(pageURL)
        return try await fetchList(pageURL)
    }
    func playlist(urn: String, accessToken: String) async throws -> SoundCloudPlaylist {
        playlistRequests.append(urn)
        return details
    }
    func playlistTracks(urn: String, accessToken: String, pageURL: URL?) async throws -> SoundCloudTrackPage {
        trackRequests.append(pageURL)
        return try await fetchTracks(pageURL)
    }
}

enum SoundCloudError: Error { case invalidData }

let user = SoundCloudUser(urn: "user:1", username: "Test", avatarURL: nil,
                         permalinkURL: URL(string: "https://soundcloud.com/test")!)
func makePlaylist(_ id: Int, isPrivate: Bool = true) -> SoundCloudPlaylist {
    SoundCloudPlaylist(urn: "playlist:\(id)", title: "Playlist \(id)", owner: user,
                       artworkURL: nil, permalinkURL: user.permalinkURL,
                       description: "Description", trackCount: 3,
                       durationMilliseconds: 3000, isPrivate: isPrivate)
}
func track(_ id: Int) -> SoundCloudTrack {
    SoundCloudTrack(urn: "track:\(id)", title: "Track \(id)", artist: user,
                    artworkURL: nil, waveformURL: nil, permalinkURL: user.permalinkURL,
                    durationMilliseconds: 1000, access: .playable, secretToken: nil)
}

@main
struct PlaylistsCacheTests {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlaylistsCacheStore(directory: directory)
        let next = URL(string: "https://api.soundcloud.com/playlists?cursor=next")!
        let baseline = PlaylistsCache(
            playlists: [makePlaylist(1), makePlaylist(2)], hasLoadedList: true,
            contents: ["playlist:1": PlaylistContents(playlist: makePlaylist(1),
                tracks: [track(1), track(2), track(3)], hasLoadedPage: true)]
        )
        try await store.save(baseline, accountID: "user:1")
        let missing = try await store.load(accountID: "user:2")
        precondition(missing == nil)
        let disk = try await PlaylistsCacheStore(directory: directory).load(accountID: "user:1")
        precondition(disk?.playlists == baseline.playlists)
        precondition(disk?.contents["playlist:1"]?.tracks == baseline.contents["playlist:1"]?.tracks)
        precondition(disk?.contents["playlist:1"]?.isComplete == true)

        // Saving only the sidebar must retain unopened playlist contents.
        try await store.save(PlaylistsCache(playlists: baseline.playlists, hasLoadedList: true), accountID: "user:1")
        let retained = try await store.loadContents(urn: "playlist:1", accountID: "user:1")
        precondition(retained?.tracks == baseline.contents["playlist:1"]?.tracks)

        // Old combined caches remain readable, one requested playlist at a time.
        let legacyDirectory = directory.appending(path: "legacy")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let sidebar = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasSuffix("-sidebar.json") }!
        let legacyURL = legacyDirectory.appending(path: sidebar.lastPathComponent.replacingOccurrences(of: "-sidebar", with: ""))
        var legacyCache = baseline
        legacyCache.contents["playlist:2"] = PlaylistContents(playlist: makePlaylist(2), tracks: [track(9)], hasLoadedPage: true)
        legacyCache.contents["playlist:9"] = PlaylistContents(playlist: makePlaylist(9), tracks: [track(9)], hasLoadedPage: true)
        try JSONEncoder().encode(legacyCache).write(to: legacyURL)
        let legacyStore = PlaylistsCacheStore(directory: legacyDirectory)
        let legacyList = try legacyStore.loadForLaunch(accountID: "user:1")
        precondition(legacyList?.contents.isEmpty == true)
        let legacyContents = try await legacyStore.loadContents(urn: "playlist:1", accountID: "user:1")
        precondition(legacyContents == baseline.contents["playlist:1"])
        try await legacyStore.save(PlaylistsCache(playlists: baseline.playlists, hasLoadedList: true), accountID: "user:1")
        let unopened = try await legacyStore.loadContents(urn: "playlist:2", accountID: "user:1")
        precondition(unopened?.tracks == [track(9)])
        let legacyFeedContents = try await legacyStore.loadContents(urn: "playlist:9", accountID: "user:1")
        precondition(legacyFeedContents == nil, "Migration must discard legacy feed-only contents")
        try await legacyStore.removeContents(urn: "playlist:1", accountID: "user:1")
        let deletedLegacy = try await legacyStore.loadContents(urn: "playlist:1", accountID: "user:1")
        precondition(deletedLegacy == nil)

        let auth = AuthController()
        let client = SoundCloudClient()
        let controller = PlaylistsController(client: client, auth: auth, store: store)
        precondition(controller.playlists == baseline.playlists,
                     "Cached playlists must be available before the first view or async task")
        precondition(controller.cache.contents.isEmpty,
                     "Startup must not decode cached track details")
        await controller.restoreCache()
        precondition(controller.playlists == baseline.playlists && client.listRequests.isEmpty)
        precondition(controller.cache.contents.isEmpty, "Background restore must load only the list")
        await controller.restoreContents(urn: "playlist:1")
        precondition(controller.cache.contents["playlist:1"]?.tracks == [track(1), track(2), track(3)])

        // Loading a newly visible card must not invalidate cards for other URNs.
        do {
            let cardClient = SoundCloudClient()
            let cardDirectory = directory.appending(path: "cards")
            defer { try? FileManager.default.removeItem(at: cardDirectory) }
            let cardStore = PlaylistsCacheStore(directory: cardDirectory)
            let cards = PlaylistsController(client: cardClient, auth: auth, store: cardStore)
            await cards.restoreCache()
            let first = cards.cardState(for: "playlist:1")
            let second = cards.cardState(for: "playlist:2")
            precondition(cards.cardState(for: "playlist:1") === first)
            let firstChanges = OSAllocatedUnfairLock(initialState: 0)
            let secondChanges = OSAllocatedUnfairLock(initialState: 0)
            withObservationTracking {
                _ = first.contents
                _ = first.isLoading
                _ = first.errorMessage
            } onChange: {
                firstChanges.withLock { $0 += 1 }
            }
            withObservationTracking {
                _ = second.contents
                _ = second.isLoading
                _ = second.errorMessage
            } onChange: {
                secondChanges.withLock { $0 += 1 }
            }
            cardClient.fetchTracks = { _ in
                precondition(first.isLoading)
                return SoundCloudTrackPage(tracks: [track(1)], nextURL: nil)
            }
            await cards.loadPlaylist(makePlaylist(1))
            precondition(firstChanges.withLock { $0 } == 1)
            precondition(secondChanges.withLock { $0 } == 0)
            precondition(first.contents?.tracks == [track(1)] && !first.isLoading)

            // An unchanged refresh does not republish card contents.
            let contentChanges = OSAllocatedUnfairLock(initialState: 0)
            withObservationTracking {
                _ = first.contents
            } onChange: {
                contentChanges.withLock { $0 += 1 }
            }
            await cards.loadPlaylist(makePlaylist(1))
            precondition(contentChanges.withLock { $0 } == 0)
            cardClient.fetchTracks = { _ in throw SoundCloudError.invalidData }
            await cards.loadPlaylist(makePlaylist(1))
            precondition(first.errorMessage != nil && !first.isLoading)
            precondition(secondChanges.withLock { $0 } == 0)
            cards.clear()
            precondition(first.contents == nil && first.errorMessage == nil)
            precondition(contentChanges.withLock { $0 } == 1)
            precondition(secondChanges.withLock { $0 } == 0)
        }

        // System playlists use their own endpoint and arrive with all tracks.
        let mixDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: mixDirectory) }
        let mixClient = SoundCloudClient()
        let mixController = PlaylistsController(client: mixClient, auth: auth,
            store: PlaylistsCacheStore(directory: mixDirectory))
        let mix = SoundCloudPlaylist.systemPlaylist(
            urn: "soundcloud:system-playlists:daily-mix:1", title: "Mix"
        )
        await mixController.loadPlaylist(mix)
        let mixContents = mixController.cache.contents[mix.urn]
        precondition(mixClient.stationRequests == [mix.urn])
        precondition(mixClient.playlistRequests.isEmpty && mixClient.trackRequests.isEmpty)
        precondition(mixContents?.isComplete == true)
        precondition(mixContents?.tracks == [track(4), track(5)])
        precondition(mixContents?.playlist.title == "Daily mix")
        precondition(mixContents?.playlist.description == "Your mix")
        precondition(mixContents?.playlist.lastModified == "2026-10-05T12:00:00Z")
        precondition(mixController.playlistErrors[mix.urn] == nil)

        client.fetchTracks = { _ in
            SoundCloudTrackPage(tracks: [track(1), track(2), track(3)], nextURL: nil)
        }
        try await controller.addTrack(track(3), to: makePlaylist(1))
        precondition(client.addedTrackURNs == [track(3).urn])
        precondition(controller.cache.contents["playlist:1"]?.tracks == [track(1), track(2), track(3)])
        client.failAddition = true
        do {
            try await controller.addTrack(track(4), to: makePlaylist(1))
            fatalError("Failed addition was accepted")
        } catch SoundCloudError.invalidData {}
        precondition(controller.cache.contents["playlist:1"]?.tracks == [track(1), track(2), track(3)])
        client.failAddition = false

        client.failRemoval = true
        do {
            try await controller.removeTrack(track(2), from: makePlaylist(1))
            fatalError("Failed removal was accepted")
        } catch SoundCloudError.invalidData {}
        precondition(controller.cache.contents["playlist:1"]?.tracks == [track(1), track(2), track(3)])
        precondition(controller.updatingPlaylistURNs.isEmpty)
        client.failRemoval = false
        client.fetchTracks = { _ in
            SoundCloudTrackPage(tracks: [track(1), track(3)], nextURL: nil)
        }
        try await controller.removeTrack(track(2), from: makePlaylist(1))
        precondition(client.removedTrackURNs == [track(2).urn])
        precondition(controller.cache.contents["playlist:1"]?.tracks == [track(1), track(3)])
        precondition(controller.updatingPlaylistURNs.isEmpty)
        let removedCache = try await store.load(accountID: user.urn!)
        precondition(removedCache?.contents["playlist:1"]?.tracks == [track(1), track(3)])
        // Restore the fixture used by the remaining refresh checks.
        client.fetchTracks = { _ in
            SoundCloudTrackPage(tracks: [track(1), track(2), track(3)], nextURL: nil)
        }
        await controller.loadPlaylist(makePlaylist(1))

        // A failed later page keeps the complete old list and track order, on disk too.
        client.fetchList = { url in
            if url == nil { return SoundCloudPlaylistPage(playlists: [makePlaylist(3)], nextURL: next) }
            throw SoundCloudError.invalidData
        }
        await controller.load()
        precondition(controller.errorMessage != nil && controller.playlists == baseline.playlists)
        client.fetchTracks = { url in
            if url == nil { return SoundCloudTrackPage(tracks: [track(3)], nextURL: next) }
            throw SoundCloudError.invalidData
        }
        await controller.loadPlaylist(makePlaylist(1))
        precondition(controller.playlistErrors["playlist:1"] != nil)
        let afterFailure = try await store.load(accountID: "user:1")
        precondition(afterFailure?.contents["playlist:1"]?.tracks == [track(1), track(2), track(3)])

        // A complete refresh detects deletions, additions, and track reordering.
        client.fetchList = { url in
            SoundCloudPlaylistPage(playlists: url == nil ? [makePlaylist(3)] : [makePlaylist(3), makePlaylist(1)],
                                   nextURL: url == nil ? next : nil)
        }
        await controller.load()
        precondition(controller.playlists == [makePlaylist(3), makePlaylist(1)])
        client.fetchTracks = { url in
            SoundCloudTrackPage(tracks: url == nil ? [track(3)] : [track(3), track(1)],
                                nextURL: url == nil ? next : nil)
        }
        await controller.loadPlaylist(makePlaylist(1))
        precondition(controller.cache.contents["playlist:1"]?.tracks == [track(3), track(1)])
        controller.clear()
        precondition(controller.playlists.isEmpty && controller.cache.contents.isEmpty)
        await controller.restoreCache()
        precondition(controller.playlists == [makePlaylist(3), makePlaylist(1)])
        precondition(controller.cache.contents.isEmpty)
        await controller.restoreContents(urn: "playlist:1")
        precondition(controller.cache.contents["playlist:1"]?.tracks == [track(3), track(1)])

        // Empty remote lists remove cached entries.
        client.fetchTracks = { _ in SoundCloudTrackPage(tracks: [], nextURL: nil) }
        await controller.loadPlaylist(makePlaylist(1))
        precondition(controller.cache.contents["playlist:1"]?.isComplete == true)
        precondition(controller.cache.contents["playlist:1"]?.tracks.isEmpty == true)
        client.fetchList = { _ in SoundCloudPlaylistPage(playlists: [], nextURL: nil) }
        await controller.load()
        precondition(controller.playlists.isEmpty && controller.cache.contents.isEmpty)

        // Refreshing the library must not clear playlist cards opened from the feed.
        client.details = makePlaylist(9)
        client.fetchTracks = { _ in SoundCloudTrackPage(tracks: [track(9)], nextURL: nil) }
        await controller.loadPlaylist(makePlaylist(9))
        await controller.load()
        precondition(controller.playlists.isEmpty)
        precondition(controller.cache.contents["playlist:9"]?.tracks == [track(9)])
        client.details = makePlaylist(1)

        // Another account starts empty. Initial pages survive a failed import.
        auth.state = .signedIn(SoundCloudUser(urn: "user:2", username: "Other", avatarURL: nil,
                                            permalinkURL: user.permalinkURL))
        await controller.restoreCache()
        precondition(controller.playlists.isEmpty)
        client.fetchList = { url in
            if url == nil { return SoundCloudPlaylistPage(playlists: [makePlaylist(1)], nextURL: next) }
            throw SoundCloudError.invalidData
        }
        await controller.load()
        client.fetchTracks = { url in
            if url == nil { return SoundCloudTrackPage(tracks: [track(1)], nextURL: next) }
            throw SoundCloudError.invalidData
        }
        await controller.loadPlaylist(makePlaylist(1))
        controller.clear()
        await controller.restoreCache()
        precondition(controller.playlists == [makePlaylist(1)] && !controller.cache.hasLoadedList)
        await controller.restoreContents(urn: "playlist:1")
        precondition(controller.cache.contents["playlist:1"]?.nextPageURL == next)

        // Repeated pagination is rejected without an endless request loop.
        client.fetchList = { _ in SoundCloudPlaylistPage(playlists: [makePlaylist(1)], nextURL: next) }
        await controller.load()
        precondition(controller.errorMessage != nil && !controller.isLoading)
        client.fetchTracks = { _ in SoundCloudTrackPage(tracks: [track(1)], nextURL: next) }
        await controller.loadPlaylist(makePlaylist(1))
        precondition(controller.playlistErrors["playlist:1"] != nil && controller.loadingPlaylistURNs.isEmpty)

        // Concurrent callers share a request; an old response cannot cross sign-out.
        var response: CheckedContinuation<SoundCloudTrackPage, Never>?
        client.fetchTracks = { _ in await withCheckedContinuation { response = $0 } }
        let requestCount = client.trackRequests.count
        let first = Task { await controller.loadPlaylist(makePlaylist(1)) }
        while response == nil { await Task.yield() }
        let second = Task { await controller.loadPlaylist(makePlaylist(1)) }
        for _ in 0..<10 { await Task.yield() }
        precondition(client.trackRequests.count == requestCount + 1)
        controller.clear()
        auth.state = .signedOut
        response?.resume(returning: SoundCloudTrackPage(tracks: [track(99)], nextURL: nil))
        await first.value
        await second.value
        precondition(controller.cache.contents.isEmpty && controller.loadingPlaylistURNs.isEmpty)
        let afterSignOut = try await store.load(accountID: "user:2")
        precondition(afterSignOut?.contents["playlist:1"]?.tracks == [track(1)])

        // A damaged cache is rebuilt on the next successful load.
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" { try Data("broken".utf8).write(to: file) }
        auth.state = .signedIn(user)
        await controller.restoreCache()
        precondition(controller.playlists.isEmpty)
        client.fetchList = { _ in SoundCloudPlaylistPage(playlists: [makePlaylist(2)], nextURL: nil) }
        await controller.load()
        let repaired = try await store.load(accountID: "user:1")
        precondition(repaired?.playlists == [makePlaylist(2)])
        // Like state must include later pages before choosing POST or DELETE.
        let publicPlaylist = makePlaylist(42, isPrivate: false)
        client.fetchLikes = { url in
            precondition(controller.isLoadingLikes)
            return SoundCloudPlaylistPage(playlists: url == nil ? [] : [publicPlaylist, publicPlaylist],
                                   nextURL: url == nil ? next : nil)
        }
        await controller.loadLikes()
        precondition(controller.hasLoadedLikes && controller.likedPlaylistURNs == [publicPlaylist.urn])
        precondition(controller.likedPlaylists == [publicPlaylist] && !controller.isLoadingLikes)
        precondition(controller.playlists == [makePlaylist(2)])
        try await controller.toggleLike(publicPlaylist)
        precondition(controller.likedPlaylists.isEmpty)
        precondition(client.likeWrites == [false] && controller.likedPlaylistURNs.isEmpty)
        try await controller.toggleLike(publicPlaylist)
        precondition(client.likeWrites == [false, true])
        precondition(controller.likedPlaylists == [publicPlaylist])
        client.failLikeWrite = true
        do {
            try await controller.toggleLike(publicPlaylist)
            fatalError("Failed like write was accepted")
        } catch is SoundCloudError {}
        precondition(controller.likedPlaylistURNs == [publicPlaylist.urn])
        precondition(controller.updatingLikeURNs.isEmpty)
        precondition(controller.likedPlaylists == [publicPlaylist])
        try await controller.toggleLike(makePlaylist(1))
        precondition(client.likeWrites.count == 3)
        controller.clear()
        try await store.save(baseline, accountID: "user:1")
        await controller.restoreCache()
        let updated = try await controller.updatePlaylist(
            makePlaylist(1), title: "Edited", description: "", isPrivate: false
        )
        precondition(controller.playlists.first == updated)
        precondition(controller.cache.contents[updated.urn]?.playlist == updated)
        precondition(controller.cache.contents[updated.urn]?.tracks == [track(1), track(2), track(3)])
        precondition(controller.cache.contents[updated.urn]?.isComplete == true)
        let savedUpdate = try await store.load(accountID: "user:1")
        precondition(savedUpdate?.playlists.first == updated)
        client.failUpdate = true
        do {
            _ = try await controller.updatePlaylist(updated, title: "Failed", description: "", isPrivate: true)
            fatalError("Failed update was accepted")
        } catch is SoundCloudError {}
        precondition(controller.playlists.first == updated)
        precondition(controller.updatingPlaylistURNs.isEmpty)
        client.failUpdate = false
        // Restore the baseline for the remaining sync checks.
        controller.clear()
        try await store.save(baseline, accountID: "user:1")
        await controller.restoreCache()

        precondition(controller.likedPlaylistURNs.isEmpty && !controller.hasLoadedLikes)
        precondition(controller.likedPlaylists.isEmpty && !controller.isLoadingLikes)
        await controller.restoreCache()
        client.fetchLikes = { url in
            if url == nil { return SoundCloudPlaylistPage(playlists: [publicPlaylist], nextURL: next) }
            throw SoundCloudError.invalidData
        }
        await controller.loadLikes()
        precondition(!controller.hasLoadedLikes && controller.likesErrorMessage != nil)
        precondition(controller.likedPlaylists.isEmpty && !controller.isLoadingLikes)
        client.fetchLikes = { _ in SoundCloudPlaylistPage(playlists: [], nextURL: nil) }
        await controller.loadLikes()
        precondition(controller.hasLoadedLikes && controller.likesErrorMessage == nil)
        let created = try await controller.createPlaylist(title: "New", description: "", isPrivate: true)
        precondition(controller.playlists.first == created)
        precondition(controller.cache.contents[created.urn]?.isComplete == true)
        let afterCreation = try await store.load(accountID: "user:1")
        precondition(afterCreation?.playlists.first == created)
        let beforeFailedCreation = controller.playlists
        client.failCreation = true
        do {
            _ = try await controller.createPlaylist(title: "New", description: "", isPrivate: true)
            fatalError("Failed creation was accepted")
        } catch is SoundCloudError {}
        precondition(controller.playlists == beforeFailedCreation)
        client.failDeletion = true
        do {
            try await controller.deletePlaylist(created)
            fatalError("Failed deletion was accepted")
        } catch is SoundCloudError {}
        precondition(controller.playlists == beforeFailedCreation)
        precondition(controller.cache.contents[created.urn] != nil)
        client.failDeletion = false
        try await controller.deletePlaylist(created)
        precondition(client.deletedURNs == [created.urn])
        precondition(!controller.playlists.contains(where: { $0.urn == created.urn }))
        precondition(controller.cache.contents[created.urn] == nil)
        let afterDeletion = try await store.load(accountID: "user:1")
        precondition(afterDeletion?.playlists == controller.playlists)
        precondition(afterDeletion?.contents[created.urn] == nil)
        // Scrolling retains one complete page for playback, without persisting previews.
        let previewStore = PlaylistsCacheStore(directory: directory.appending(path: "previews"))
        let previewClient = SoundCloudClient()
        previewClient.fetchTracks = { _ in
            SoundCloudTrackPage(tracks: (1...10).map(track), nextURL: next)
        }
        let previewController = PlaylistsController(client: previewClient, auth: AuthController(), store: previewStore)
        let previewState = previewController.cardState(for: "playlist:100")
        await previewController.loadPreview(makePlaylist(100))
        precondition(previewClient.trackRequests.count == 1 && previewClient.playlistRequests.isEmpty)
        precondition(previewState.contents?.tracks.count == 10,
                     "Playback must retain tracks beyond the five visible rows")
        precondition(previewState.contents?.nextPageURL == next)
        precondition(previewState.contents?.isComplete == false)
        precondition(previewController.cache.contents.isEmpty)
        let previewDisk = try await previewStore.load(accountID: "user:1")
        precondition(previewDisk == nil)
        await previewController.loadPreview(makePlaylist(100))
        precondition(previewClient.trackRequests.count == 1)
        for id in 101...140 { await previewController.loadPreview(makePlaylist(id)) }
        precondition(previewState.contents == nil, "Old previews must release their tracks")
        await previewController.loadPreview(makePlaylist(100))
        precondition(previewClient.trackRequests.count == 42)
        previewClient.fetchTracks = { url in
            SoundCloudTrackPage(tracks: url == nil ? [track(1)] : [track(2)], nextURL: url == nil ? next : nil)
        }
        await previewController.loadPlaylist(makePlaylist(100))
        precondition(previewController.cache.contents["playlist:100"]?.tracks == [track(1), track(2)])

        // A final page must also retain hidden tracks: there is no cursor to recover them.
        previewClient.fetchTracks = { _ in
            SoundCloudTrackPage(tracks: (1...10).map(track), nextURL: nil)
        }
        await previewController.loadPreview(makePlaylist(141))
        let completePreview = previewController.cardState(for: "playlist:141").contents
        precondition(completePreview?.tracks == (1...10).map(track))
        precondition(completePreview?.isComplete == true)

        // Disk retention protects sidebar playlists and bounds external contents.
        var bounded = baseline
        for id in 100...130 {
            bounded.contents["playlist:\(id)"] = PlaylistContents(playlist: makePlaylist(id), tracks: [track(id)], hasLoadedPage: true)
        }
        let boundedStore = PlaylistsCacheStore(directory: directory.appending(path: "bounded"))
        try await boundedStore.save(bounded, accountID: "user:1")
        let boundedDisk = try await boundedStore.load(accountID: "user:1")
        precondition(boundedDisk?.contents.count == 21)
        precondition(boundedDisk?.contents["playlist:1"] == baseline.contents["playlist:1"])
        precondition(!FileManager.default.fileExists(atPath: legacyURL.path))

        // Sidebar covers resolve without opening a playlist and survive relaunch.
        let coverURL = URL(string: "https://example.com/cover.jpg")!
        let coverTrack = SoundCloudTrack(
            urn: "track:cover", title: "Cover", artist: user, artworkURL: coverURL,
            waveformURL: nil, permalinkURL: user.permalinkURL,
            durationMilliseconds: 1000, access: .playable, secretToken: nil
        )
        let coverDirectory = directory.appending(path: "covers")
        let coverStore = PlaylistsCacheStore(directory: coverDirectory)
        try await coverStore.save(PlaylistsCache(playlists: [makePlaylist(1)], hasLoadedList: true), accountID: "user:1")
        let coverClient = SoundCloudClient()
        coverClient.fetchTracks = { _ in SoundCloudTrackPage(tracks: [coverTrack], nextURL: next) }
        let coverController = PlaylistsController(client: coverClient, auth: AuthController(), store: coverStore)
        await coverController.loadArtwork(for: makePlaylist(1))
        precondition(coverController.artworkURL(for: makePlaylist(1)) == coverURL)
        precondition(coverController.cache.contents.isEmpty)
        precondition(coverClient.trackRequests.count == 1 && coverClient.playlistRequests.isEmpty)
        let coverRelaunch = PlaylistsController(client: coverClient, auth: AuthController(), store: coverStore)
        precondition(coverRelaunch.artworkURL(for: makePlaylist(1)) == coverURL)
        precondition(coverRelaunch.cache.contents.isEmpty)
        await coverRelaunch.loadArtwork(for: makePlaylist(1))
        precondition(coverClient.trackRequests.count == 1, "A saved cover must not fetch tracks again")

        // Old caches can resolve the cover from disk without publishing track contents.
        try await coverStore.save(PlaylistsCache(
            playlists: [makePlaylist(1)], hasLoadedList: true,
            contents: ["playlist:1": PlaylistContents(playlist: makePlaylist(1), tracks: [coverTrack], hasLoadedPage: true)]
        ), accountID: "user:1")
        let coverSidebar = try FileManager.default.contentsOfDirectory(at: coverDirectory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasSuffix("-sidebar.json") }!
        var oldSidebar = try JSONSerialization.jsonObject(with: Data(contentsOf: coverSidebar)) as! [String: Any]
        oldSidebar.removeValue(forKey: "artworkURLs")
        try JSONSerialization.data(withJSONObject: oldSidebar).write(to: coverSidebar)
        let oldCoverController = PlaylistsController(client: coverClient, auth: AuthController(), store: coverStore)
        await oldCoverController.loadArtwork(for: makePlaylist(1))
        precondition(oldCoverController.artworkURL(for: makePlaylist(1)) == coverURL)
        precondition(oldCoverController.cache.contents.isEmpty && coverClient.trackRequests.count == 1)

        print("Playlist cache and sync checks passed")
    }
}
