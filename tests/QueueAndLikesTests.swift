import Foundation

// Compile this suite with Models, TrackQueue, LikesCache, and LikesController.
// These test doubles avoid Keychain access and make network waits deterministic.
@MainActor
final class AuthController {
    enum State { case signedIn(SoundCloudUser), signedOut }
    var state: State = .signedIn(user)
    func validAccessToken() async throws -> String { "test" }
}

@MainActor
final class SoundCloudClient {
    var requestedURLs: [URL?] = []
    var fetch: (URL?) async throws -> SoundCloudTrackPage = { _ in
        SoundCloudTrackPage(tracks: [], nextURL: nil)
    }
    func likedTracks(accessToken: String, pageURL: URL?, pageSize: Int?) async throws -> SoundCloudTrackPage {
        precondition(pageSize == 200)
        requestedURLs.append(pageURL)
        return try await fetch(pageURL)
    }
    func setTrackLiked(urn: String, isLiked: Bool, accessToken: String) async throws {}
}

enum SoundCloudError: Error { case invalidData }

let user = SoundCloudUser(urn: "user:1", username: "Test", avatarURL: nil,
                          permalinkURL: URL(string: "https://soundcloud.com/test")!)
func track(_ id: Int) -> SoundCloudTrack {
    SoundCloudTrack(urn: "track:\(id)", title: "Track \(id)", artist: user,
                    artworkURL: nil, waveformURL: nil,
                    permalinkURL: URL(string: "https://soundcloud.com/test/\(id)")!,
                    durationMilliseconds: 1000, access: .playable, secretToken: nil)
}

@main
struct QueueAndLikesTests {
    @MainActor
    static func main() async throws {
        let next = URL(string: "https://api.soundcloud.com/tracks?cursor=next")!
        var queue = TrackQueue(source: .artist("user:1"), tracks: [track(1), track(2)], nextPageURL: next)
        queue.replaceLikes([track(99)])
        precondition(queue.relativeTrack(to: "track:1", offset: 1, shuffle: false) == track(2))
        precondition(queue.relativeTrack(to: "track:2", offset: -1, shuffle: false) == track(1))
        precondition(!queue.needsNextPage(after: "track:1"))
        precondition(queue.needsNextPage(after: "track:2"))
        // Shuffle returns a loaded artist track without fetching the next page.
        precondition(queue.relativeTrack(to: "track:1", offset: 1, shuffle: true) == track(2))
        do {
            try queue.append(SoundCloudTrackPage(tracks: [], nextURL: next))
            fatalError("Repeated cursor accepted")
        } catch SoundCloudError.invalidData {}
        try queue.append(SoundCloudTrackPage(tracks: [track(2), track(3)], nextURL: nil))
        precondition(queue.tracks == [track(1), track(2), track(3)])
        precondition(queue.relativeTrack(to: "track:2", offset: 1, shuffle: false) == track(3))
        precondition(queue.relativeTrack(to: "track:3", offset: 1, shuffle: false) == track(1))
        var restored = try JSONDecoder().decode(TrackQueue.self, from: JSONEncoder().encode(queue))
        precondition(restored.source == .artist("user:1"))
        precondition(restored.relativeTrack(to: "track:2", offset: 1, shuffle: false) == track(3))
        var likesQueue = TrackQueue(source: .likes, tracks: [track(1), track(2), track(3)])
        let shuffled = likesQueue.relativeTrack(to: "track:1", offset: 1, shuffle: true)!
        precondition(shuffled != track(1))
        precondition(likesQueue.relativeTrack(to: shuffled.urn, offset: -1, shuffle: true) == track(1))
        likesQueue.replaceLikes([track(1), track(4)])
        precondition(likesQueue.relativeTrack(to: "track:1", offset: 1, shuffle: true) == track(4))

        let baseline = LikesCache(tracks: [track(1), track(2), track(3), track(4)], hasLoadedPage: true)
        var merged = baseline
        precondition(merged.mergeHead([track(5), track(2), track(4)], nextURL: next, baseline: baseline))
        precondition(merged.tracks == [track(5), track(2), track(4), track(1), track(3)])
        precondition(merged.nextPageURL == nil)
        precondition(merged.mergeHead([track(4), track(1), track(2)], nextURL: next, baseline: baseline))
        precondition(merged.tracks == [track(4), track(1), track(2), track(3)]) // A re-like moved to the top.

        precondition(!merged.mergeHead([track(4), track(6)], nextURL: next, baseline: baseline))
        precondition(merged.mergeHead([track(5)], nextURL: nil, baseline: baseline))
        precondition(merged.tracks == [track(5)]) // A complete response can confirm removals.

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LikesCacheStore(directory: directory)
        try await store.save(baseline, accountID: "user:1")
        let missing = try await store.load(accountID: "user:2")
        precondition(missing == nil)
        let disk = try await LikesCacheStore(directory: directory).load(accountID: "user:1")
        precondition(disk?.tracks == baseline.tracks)

        let auth = AuthController()
        let client = SoundCloudClient()
        let likes = LikesController(client: client, auth: auth, store: store)
        await likes.restoreCache()
        precondition(likes.tracks == baseline.tracks && client.requestedURLs.isEmpty)
        client.fetch = { url in
            precondition(url == nil)
            return SoundCloudTrackPage(tracks: [track(5), track(1), track(2)], nextURL: next)
        }
        await likes.loadLikedTracks()
        precondition(client.requestedURLs.count == 1) // No full refetch on reopening.
        precondition(likes.tracks == [track(5), track(1), track(2), track(3), track(4)])
        try await likes.toggleLike(track(2))
        let afterUnlike = try await store.load(accountID: "user:1")
        precondition(afterUnlike?.tracks.contains(track(2)) == false)
        client.fetch = { _ in throw SoundCloudError.invalidData }
        await likes.loadLikedTracks()
        precondition(likes.errorMessage != nil && likes.tracks.contains(track(5)))
        likes.clear()
        precondition(likes.tracks.isEmpty)
        await likes.restoreCache()
        precondition(likes.tracks.contains(track(5)))

        // An interrupted initial import keeps its continuation on disk.
        auth.state = .signedIn(SoundCloudUser(urn: "user:2", username: "Other", avatarURL: nil,
                                           permalinkURL: user.permalinkURL))
        likes.clear()
        client.requestedURLs = []
        client.fetch = { url in
            if url == nil { return SoundCloudTrackPage(tracks: [track(1)], nextURL: next) }
            throw SoundCloudError.invalidData
        }
        await likes.loadLikedTracks()
        precondition(likes.tracks == [track(1)] && likes.canLoadMore)
        let partial = try await store.load(accountID: "user:2")
        precondition(partial?.nextPageURL == next)
        likes.clear()
        client.requestedURLs = []
        client.fetch = { url in
            if url == nil { return SoundCloudTrackPage(tracks: [track(5), track(1)], nextURL: next) }
            return SoundCloudTrackPage(tracks: [track(2)], nextURL: nil)
        }
        await likes.loadLikedTracks()
        precondition(client.requestedURLs == [nil, next])
        precondition(likes.tracks == [track(5), track(1), track(2)] && !likes.canLoadMore)

        // A like/unlike completed during refresh wins over the stale response.
        var editResponse: CheckedContinuation<SoundCloudTrackPage, Never>?
        client.fetch = { _ in await withCheckedContinuation { editResponse = $0 } }
        let editSync = Task { await likes.loadLikedTracks() }
        while editResponse == nil { await Task.yield() }
        try await likes.toggleLike(track(1))
        try await likes.toggleLike(track(8))
        editResponse?.resume(returning: SoundCloudTrackPage(tracks: [track(5), track(1)], nextURL: next))
        await editSync.value
        precondition(likes.tracks == [track(8), track(5), track(2)])

        // Sign-out during a request must not repopulate another account's state.
        var pending: CheckedContinuation<SoundCloudTrackPage, Never>?
        client.fetch = { _ in await withCheckedContinuation { pending = $0 } }
        let sync = Task { await likes.loadLikedTracks() }
        while pending == nil { await Task.yield() }
        likes.clear()
        pending?.resume(returning: SoundCloudTrackPage(tracks: [track(99)], nextURL: nil))
        await sync.value
        precondition(likes.tracks.isEmpty && !likes.isLoading)
        print("Queue and likes tests passed")
    }
}
