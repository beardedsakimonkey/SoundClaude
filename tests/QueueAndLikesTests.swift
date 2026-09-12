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
    var setLike: () async throws -> Void = {}
    func setTrackLiked(urn: String, isLiked: Bool, accessToken: String) async throws {
        try await setLike()
    }
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
        // Manual additions append once, preserve pagination, and can start an empty queue.
        var added = TrackQueue(source: .single, tracks: [])
        precondition(added.add(track(1)))
        precondition(!added.add(track(1)))
        precondition(added.relativeTrack(to: nil, offset: 1) == track(1))
        added = TrackQueue(source: .artist("user:1"), tracks: [track(1), track(2)], nextPageURL: next)
        added.setShuffle(true, currentURN: "track:1")
        let originalOrder = added.playbackTracks
        precondition(added.add(track(3)))
        precondition(added.playbackTracks == originalOrder + [track(3)])
        precondition(added.nextPageURL == next)
        added = try JSONDecoder().decode(TrackQueue.self, from: JSONEncoder().encode(added))
        precondition(added.playbackTracks == originalOrder + [track(3)])
        try added.append(SoundCloudTrackPage(tracks: [track(3), track(4)], nextURL: nil))
        precondition(added.playbackTracks == originalOrder + [track(3), track(4)])

        // Added tracks survive likes refreshes, reordering, shuffle, and metadata-free saves.
        var addedLikes = TrackQueue(source: .likes, tracks: [track(1), track(2)])
        precondition(addedLikes.add(track(3)))
        addedLikes.replaceLikes([track(4), track(2), track(1)])
        precondition(addedLikes.tracks == [track(1), track(2), track(3), track(4)])
        precondition(addedLikes.move(fromOffsets: IndexSet(integer: 2), toOffset: 1))
        addedLikes.setShuffle(true, currentURN: "track:1")
        let addedLikesOrder = addedLikes.playbackTracks
        addedLikes = try JSONDecoder().decode(
            TrackQueue.self, from: JSONEncoder().encode(addedLikes.withoutLikesMetadata())
        )
        addedLikes.replaceLikes([track(4), track(2), track(1)])
        precondition(addedLikes.playbackTracks == addedLikesOrder)
        addedLikes.setShuffle(false, currentURN: "track:1")
        precondition(addedLikes.tracks == [track(1), track(3), track(2), track(4)])
        addedLikes.replaceLikes([track(3), track(1)])
        precondition(addedLikes.tracks == [track(1), track(3)])
        addedLikes.replaceLikes([track(1)])
        precondition(addedLikes.tracks == [track(1), track(3)])

        var queue = TrackQueue(source: .artist("user:1"), tracks: [track(1), track(2)], nextPageURL: next)
        queue.replaceLikes([track(99)])
        precondition(queue.relativeTrack(to: "track:1", offset: 1) == track(2))
        precondition(queue.relativeTrack(to: "track:2", offset: -1) == track(1))
        precondition(!queue.needsNextPage(after: "track:1"))
        precondition(queue.needsNextPage(after: "track:2"))
        // Shuffle returns a loaded artist track without fetching the next page.
        queue.setShuffle(true, currentURN: "track:1")
        precondition(queue.relativeTrack(to: "track:1", offset: 1) == track(2))
        queue.setShuffle(false, currentURN: "track:1")
        do {
            try queue.append(SoundCloudTrackPage(tracks: [], nextURL: next))
            fatalError("Repeated cursor accepted")
        } catch SoundCloudError.invalidData {}
        try queue.append(SoundCloudTrackPage(tracks: [track(2), track(3)], nextURL: nil))
        precondition(queue.tracks == [track(1), track(2), track(3)])
        precondition(queue.relativeTrack(to: "track:2", offset: 1) == track(3))
        precondition(queue.relativeTrack(to: "track:3", offset: 1) == track(1))
        // Automatic advance stops at the end unless repeat-all permits wrapping.
        precondition(queue.relativeTrack(to: "track:2", offset: 1, wraps: false) == track(3))
        precondition(queue.relativeTrack(to: "track:3", offset: 1, wraps: false) == nil)
        precondition(queue.relativeTrack(to: "track:3", offset: 1, wraps: true) == track(1))
        var repeatQueue = queue
        repeatQueue.setShuffle(true, currentURN: "track:2")
        let shuffledEnd = repeatQueue.playbackTracks.last!.urn
        precondition(repeatQueue.relativeTrack(to: shuffledEnd, offset: 1, wraps: false) == nil)
        precondition(repeatQueue.relativeTrack(to: shuffledEnd, offset: 1, wraps: true)
                     == repeatQueue.playbackTracks.first)
        let single = TrackQueue(source: .single, tracks: [track(1)])
        precondition(single.relativeTrack(to: "track:1", offset: 1, wraps: false) == nil)
        precondition(single.relativeTrack(to: "track:1", offset: 1, wraps: true) == track(1))
        let restored = try JSONDecoder().decode(TrackQueue.self, from: JSONEncoder().encode(queue))
        precondition(restored.source == .artist("user:1"))
        precondition(restored.relativeTrack(to: "track:2", offset: 1) == track(3))
        var likesQueue = TrackQueue(source: .likes, tracks: [track(1), track(2), track(3)])
        likesQueue.setShuffle(true, currentURN: "track:1")
        let shuffled = likesQueue.relativeTrack(to: "track:1", offset: 1)!
        precondition(shuffled != track(1))
        precondition(likesQueue.relativeTrack(to: shuffled.urn, offset: -1) == track(1))
        likesQueue.replaceLikes([track(1), track(4)])
        precondition(likesQueue.relativeTrack(to: "track:1", offset: 1) == track(4))

        // Moves use insertion offsets in the original list, including the end.
        var reordered = TrackQueue(source: .playlist("playlist:1"),
                                   tracks: [track(1), track(2), track(3), track(4)], nextPageURL: next)
        precondition(reordered.move(fromOffsets: IndexSet(integer: 0), toOffset: 4))
        precondition(reordered.tracks == [track(2), track(3), track(4), track(1)])
        precondition(reordered.relativeTrack(to: "track:4", offset: 1) == track(1))
        precondition(reordered.needsNextPage(after: "track:1"))
        precondition(reordered.move(fromOffsets: IndexSet(integer: 3), toOffset: 0))
        precondition(reordered.tracks == [track(1), track(2), track(3), track(4)])
        precondition(reordered.move(fromOffsets: IndexSet([0, 2]), toOffset: 4))
        precondition(reordered.tracks == [track(2), track(4), track(1), track(3)])
        precondition(reordered.relativeTrack(to: "track:1", offset: -1) == track(4))
        precondition(!reordered.move(fromOffsets: IndexSet(integer: 1), toOffset: 2))
        precondition(!reordered.move(fromOffsets: IndexSet(integer: 4), toOffset: 0))
        precondition(!reordered.move(fromOffsets: IndexSet(), toOffset: 0))
        precondition(!reordered.move(fromOffsets: IndexSet(integer: 0), toOffset: -1))
        precondition(!reordered.move(fromOffsets: IndexSet(integer: 0), toOffset: 5))
        var savedOrder = try JSONDecoder().decode(TrackQueue.self, from: JSONEncoder().encode(reordered))
        precondition(savedOrder.tracks == reordered.tracks && savedOrder.nextPageURL == next)
        try savedOrder.append(SoundCloudTrackPage(tracks: [track(1), track(5)], nextURL: nil))
        precondition(savedOrder.tracks == [track(2), track(4), track(1), track(3), track(5)])

        // Likes retain their manual order across refreshes and metadata-free persistence.
        var orderedLikes = TrackQueue(source: .likes, tracks: [track(1), track(2), track(3)])
        orderedLikes.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        orderedLikes.replaceLikes([track(4), track(1), track(3)])
        precondition(orderedLikes.tracks == [track(3), track(1), track(4)])
        orderedLikes = orderedLikes.withoutLikesMetadata()
        var savedLikes = try JSONDecoder().decode(TrackQueue.self, from: JSONEncoder().encode(orderedLikes))
        precondition(savedLikes.tracks.isEmpty)
        savedLikes.replaceLikes([track(4), track(1), track(3)])
        precondition(savedLikes.tracks == [track(3), track(1), track(4)])
        precondition(savedLikes.relativeTrack(to: "track:3", offset: 1) == track(1))
        // Queues saved before reordering was supported still decode and follow likes order.
        let legacyData = try JSONEncoder().encode(TrackQueue(source: .likes, tracks: []))
        var legacyQueue = try JSONDecoder().decode(TrackQueue.self, from: legacyData)
        legacyQueue.replaceLikes([track(3), track(2)])
        precondition(legacyQueue.tracks == [track(3), track(2)])

        // Shuffle is visible before any navigation, and navigation never changes it.
        var eager = TrackQueue(source: .artist("user:1"),
                               tracks: (1...8).map(track), nextPageURL: next)
        eager.move(fromOffsets: IndexSet(integer: 0), toOffset: 8)
        let beforeShuffle = eager.playbackTracks
        eager.setShuffle(true, currentURN: "track:4")
        let initialShuffle = eager.playbackTracks
        precondition(eager.isShuffled && initialShuffle.first == track(4))
        precondition(Set(initialShuffle.map(\.urn)) == Set(beforeShuffle.map(\.urn)))
        precondition(eager.resolvedTracks(likes: []) == initialShuffle)
        for index in initialShuffle.indices {
            let current = initialShuffle[index]
            precondition(eager.relativeTrack(to: current.urn, offset: 1)
                         == initialShuffle[(index + 1) % initialShuffle.count])
            precondition(eager.relativeTrack(to: current.urn, offset: -1)
                         == initialShuffle[(index + initialShuffle.count - 1) % initialShuffle.count])
        }
        precondition(eager.playbackTracks == initialShuffle)
        eager.setShuffle(true, currentURN: "track:4") // Restoring an enabled queue keeps its order.
        precondition(eager.playbackTracks == initialShuffle)
        precondition(eager.move(fromOffsets: IndexSet(integer: 7), toOffset: 1))
        let editedShuffle = [initialShuffle[0], initialShuffle[7]] + Array(initialShuffle[1..<7])
        precondition(eager.isShuffled && eager.playbackTracks == editedShuffle)
        precondition(eager.relativeTrack(to: "track:4", offset: 1) == initialShuffle[7])
        var restoredShuffle = try JSONDecoder().decode(TrackQueue.self, from: JSONEncoder().encode(eager))
        restoredShuffle.setShuffle(true, currentURN: "track:4")
        precondition(restoredShuffle.playbackTracks == editedShuffle)
        precondition(restoredShuffle.nextPageURL == next)
        restoredShuffle.setShuffle(false, currentURN: "track:4")
        precondition(!restoredShuffle.isShuffled && restoredShuffle.playbackTracks == beforeShuffle)

        // Shuffled likes survive metadata-free saves and retain their order as likes change.
        var shuffledLikes = TrackQueue(source: .likes, tracks: (1...4).map(track))
        shuffledLikes.setShuffle(true, currentURN: "track:2")
        shuffledLikes.move(fromOffsets: IndexSet(integer: 3), toOffset: 1)
        let likesOrder = shuffledLikes.playbackTracks
        let shuffledLikesData = try JSONEncoder().encode(shuffledLikes.withoutLikesMetadata())
        shuffledLikes = try JSONDecoder().decode(TrackQueue.self, from: shuffledLikesData)
        precondition(shuffledLikes.tracks.isEmpty && shuffledLikes.isShuffled)
        precondition(shuffledLikes.resolvedTracks(likes: (1...4).map(track)) == likesOrder)
        shuffledLikes.replaceLikes((1...4).map(track))
        shuffledLikes.setShuffle(true, currentURN: "track:2")
        precondition(shuffledLikes.playbackTracks == likesOrder)
        let removedURN = likesOrder[2].urn
        let refreshedLikes = [track(5)] + (1...4).map(track).filter { $0.urn != removedURN }
        let refreshedOrder = likesOrder.filter { $0.urn != removedURN } + [track(5)]
        precondition(shuffledLikes.resolvedTracks(likes: refreshedLikes) == refreshedOrder)
        shuffledLikes.replaceLikes(refreshedLikes)
        precondition(shuffledLikes.playbackTracks == refreshedOrder)
        shuffledLikes.replaceLikes([track(6)] + refreshedLikes)
        precondition(shuffledLikes.playbackTracks == refreshedOrder + [track(6)])

        // Empty queues retain shuffle mode when the first likes arrive.
        var emptyShuffle = TrackQueue(source: .likes, tracks: [])
        emptyShuffle.setShuffle(true, currentURN: nil)
        precondition(emptyShuffle.isShuffled && emptyShuffle.relativeTrack(to: nil, offset: 1) == nil)
        emptyShuffle.replaceLikes([track(1)])
        precondition(emptyShuffle.playbackTracks == [track(1)] && emptyShuffle.isShuffled)

        // Older saved shuffle orders remain usable without generating a new random order.
        var legacyShuffleJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(eager)) as! [String: Any]
        legacyShuffleJSON.removeValue(forKey: "shuffleEnabled")
        var legacyShuffle = try JSONDecoder().decode(
            TrackQueue.self, from: JSONSerialization.data(withJSONObject: legacyShuffleJSON)
        )
        legacyShuffle.setShuffle(true, currentURN: "track:4")
        precondition(legacyShuffle.isShuffled && legacyShuffle.playbackTracks == editedShuffle)

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

        // Counts follow successful toggles even when callers retain the original track.
        var countedTrack = track(20)
        countedTrack.likesCount = 1_234
        precondition(likes.likeCount(for: countedTrack) == 1_234)
        try await likes.toggleLike(countedTrack)
        precondition(likes.isLiked(countedTrack) && likes.likeCount(for: countedTrack) == 1_235)
        try await likes.toggleLike(countedTrack)
        precondition(!likes.isLiked(countedTrack) && likes.likeCount(for: countedTrack) == 1_234)
        client.setLike = { throw SoundCloudError.invalidData }
        do {
            try await likes.toggleLike(countedTrack)
            fatalError("Failed like accepted")
        } catch SoundCloudError.invalidData {}
        precondition(!likes.isLiked(countedTrack) && likes.likeCount(for: countedTrack) == 1_234)
        client.setLike = {}

        // Missing counts stay unknown; stale zero counts never become negative.
        try await likes.toggleLike(track(21))
        precondition(likes.likeCount(for: track(21)) == nil)
        try await likes.toggleLike(track(21))
        var zeroTrack = track(1)
        zeroTrack.likesCount = 0
        try await likes.toggleLike(zeroTrack)
        precondition(likes.likeCount(for: zeroTrack) == 0)
        try await likes.toggleLike(zeroTrack)
        precondition(likes.likeCount(for: zeroTrack) == 1)
        likes.clear()
        precondition(likes.likeCount(for: zeroTrack) == 0)
        await likes.restoreCache()

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
