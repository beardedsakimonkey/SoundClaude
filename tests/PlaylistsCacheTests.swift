import Foundation

@MainActor
final class AuthController {
    enum State { case signedIn(SoundCloudUser), signedOut }
    var state: State = .signedIn(user)
    func validAccessToken() async throws -> String { "test" }
}

@MainActor
final class SoundCloudClient {
    var listRequests: [URL?] = []
    var trackRequests: [URL?] = []
    var fetchList: (URL?) async throws -> SoundCloudPlaylistPage = { _ in
        SoundCloudPlaylistPage(playlists: [], nextURL: nil)
    }
    var fetchTracks: (URL?) async throws -> SoundCloudTrackPage = { _ in
        SoundCloudTrackPage(tracks: [], nextURL: nil)
    }
    var details = makePlaylist(1)
    func playlists(accessToken: String, pageURL: URL?) async throws -> SoundCloudPlaylistPage {
        listRequests.append(pageURL)
        return try await fetchList(pageURL)
    }
    func playlist(urn: String, accessToken: String) async throws -> SoundCloudPlaylist { details }
    func playlistTracks(urn: String, accessToken: String, pageURL: URL?) async throws -> SoundCloudTrackPage {
        trackRequests.append(pageURL)
        return try await fetchTracks(pageURL)
    }
}

enum SoundCloudError: Error { case invalidData }

let user = SoundCloudUser(urn: "user:1", username: "Test", avatarURL: nil,
                         permalinkURL: URL(string: "https://soundcloud.com/test")!)
func makePlaylist(_ id: Int) -> SoundCloudPlaylist {
    SoundCloudPlaylist(urn: "playlist:\(id)", title: "Playlist \(id)", owner: user,
                       artworkURL: nil, permalinkURL: user.permalinkURL,
                       description: "Description", trackCount: 3,
                       durationMilliseconds: 3000, isPrivate: true)
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

        let auth = AuthController()
        let client = SoundCloudClient()
        let controller = PlaylistsController(client: client, auth: auth, store: store)
        await controller.restoreCache()
        precondition(controller.playlists == baseline.playlists && client.listRequests.isEmpty)
        precondition(controller.cache.contents["playlist:1"]?.tracks == [track(1), track(2), track(3)])

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
        precondition(controller.cache.contents["playlist:1"]?.tracks == [track(3), track(1)])

        // Empty remote lists remove cached entries.
        client.fetchTracks = { _ in SoundCloudTrackPage(tracks: [], nextURL: nil) }
        await controller.loadPlaylist(makePlaylist(1))
        precondition(controller.cache.contents["playlist:1"]?.isComplete == true)
        precondition(controller.cache.contents["playlist:1"]?.tracks.isEmpty == true)
        client.fetchList = { _ in SoundCloudPlaylistPage(playlists: [], nextURL: nil) }
        await controller.load()
        precondition(controller.playlists.isEmpty && controller.cache.contents.isEmpty)

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
        for file in files { try Data("broken".utf8).write(to: file) }
        auth.state = .signedIn(user)
        await controller.restoreCache()
        precondition(controller.playlists.isEmpty)
        client.fetchList = { _ in SoundCloudPlaylistPage(playlists: [makePlaylist(2)], nextURL: nil) }
        await controller.load()
        let repaired = try await store.load(accountID: "user:1")
        precondition(repaired?.playlists == [makePlaylist(2)])
        print("Playlist cache and sync checks passed")
    }
}
