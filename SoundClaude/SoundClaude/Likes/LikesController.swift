import Combine
import Foundation

@MainActor
final class LikesController: ObservableObject {
    @Published private(set) var tracks: [SoundCloudTrack] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private var pendingLikes: [String: Bool] = [:]
    @Published private var updatedLikeCounts: [String: Int] = [:]

    private let client: SoundCloudClient
    private let auth: AuthController
    private let store: LikesCacheStore
    private var cache = LikesCache()
    private var accountID: String?
    private var sessionID = UUID()
    private var restoreTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var localChanges: [String: SoundCloudTrack] = [:]
    private var unlikedTrackURNs: Set<String> = []

    var canLoadMore: Bool { cache.nextPageURL != nil }
    var isLoadingMore: Bool { isLoading && !tracks.isEmpty }
    var updatingTrackURNs: Set<String> { Set(pendingLikes.keys) }

    init(client: SoundCloudClient, auth: AuthController, store: LikesCacheStore = LikesCacheStore()) {
        self.client = client
        self.auth = auth
        self.store = store
    }

    func restoreCache() async {
        if let restoreTask {
            await restoreTask.value
            return
        }
        guard case let .signedIn(user) = auth.state else { return }
        let id = user.urn ?? user.permalinkURL.absoluteString
        guard accountID != id else { return }
        clear()
        accountID = id
        let session = sessionID
        let task = Task { @MainActor in
            // A missing or damaged cache can be rebuilt from the API.
            let saved = try? await store.load(accountID: id)
            guard sessionID == session else { return }
            cache = saved ?? LikesCache()
            tracks = cache.tracks
            restoreTask = nil
        }
        restoreTask = task
        await task.value
    }

    func isLiked(_ track: SoundCloudTrack) -> Bool {
        pendingLikes[track.urn] ?? tracks.contains { $0.urn == track.urn }
    }

    func likeCount(for track: SoundCloudTrack) -> Int? {
        updatedLikeCounts[track.urn] ?? track.likesCount
    }

    func toggleLike(_ track: SoundCloudTrack) async throws {
        await restoreCache()
        guard let accountID, pendingLikes[track.urn] == nil else { return }
        let session = sessionID
        let shouldLike = !isLiked(track)
        pendingLikes[track.urn] = shouldLike
        do {
            let accessToken = try await auth.validAccessToken()
            guard sessionID == session else { return }
            try await client.setTrackLiked(urn: track.urn, isLiked: shouldLike, accessToken: accessToken)
        } catch {
            if sessionID == session { pendingLikes.removeValue(forKey: track.urn) }
            throw error
        }
        guard sessionID == session else { return }
        // Track details can remain cached after the like state changes.
        if let count = likeCount(for: track) {
            updatedLikeCounts[track.urn] = max(0, count + (shouldLike ? 1 : -1))
        }
        if shouldLike {
            unlikedTrackURNs.remove(track.urn)
            localChanges[track.urn] = track
            cache.tracks.removeAll { $0.urn == track.urn }
            cache.tracks.insert(track, at: 0)
        } else {
            localChanges.removeValue(forKey: track.urn)
            unlikedTrackURNs.insert(track.urn)
            cache.tracks.removeAll { $0.urn == track.urn }
        }
        tracks = cache.tracks
        pendingLikes.removeValue(forKey: track.urn)
        try await store.save(cache, accountID: accountID)
    }

    /// Sync on entry to Likes. Cached tracks remain playable during all requests.
    func loadLikedTracks() async {
        await restoreCache()
        if let syncTask {
            await syncTask.value
            return
        }
        guard let accountID else { return }
        let session = sessionID
        isLoading = true
        errorMessage = nil
        let task = Task { @MainActor in
            defer {
                if sessionID == session {
                    syncTask = nil
                    isLoading = false
                }
            }
            do {
                let baseline = cache
                localChanges = [:]
                unlikedTrackURNs = []
                if baseline.tracks.isEmpty {
                    cache = LikesCache()
                } else if baseline.hasLoadedPage {
                    var head: [SoundCloudTrack] = []
                    var url: URL?
                    var visited = Set<URL>()
                    while true {
                        let page = try await fetchPage(url, session: session)
                        try validate(page, requestedURL: url, visited: &visited)
                        head.append(contentsOf: page.tracks)
                        var refreshed = baseline
                        if refreshed.mergeHead(head, nextURL: page.nextURL, baseline: baseline) {
                            cache = refreshed
                            try await publishAndSave(accountID: accountID, session: session)
                            break
                        }
                        url = page.nextURL
                        try await Task.sleep(for: .milliseconds(350))
                    }
                }
                // First import, or resume an import interrupted in an earlier run.
                var visited = Set<URL>()
                while !cache.hasLoadedPage || cache.nextPageURL != nil {
                    let url = cache.nextPageURL
                    let page = try await fetchPage(url, session: session)
                    try validate(page, requestedURL: url, visited: &visited)
                    cache.append(page)
                    try await publishAndSave(accountID: accountID, session: session)
                    if cache.nextPageURL != nil {
                        try await Task.sleep(for: .milliseconds(350))
                    }
                }
            } catch {
                if sessionID == session, !Task.isCancelled, !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                }
            }
        }
        syncTask = task
        await task.value
    }

    func loadMore() async {
        await loadLikedTracks()
    }

    private func fetchPage(_ url: URL?, session: UUID) async throws -> SoundCloudTrackPage {
        try Task.checkCancellation()
        guard sessionID == session else { throw CancellationError() }
        let accessToken = try await auth.validAccessToken()
        try Task.checkCancellation()
        guard sessionID == session else { throw CancellationError() }
        let page = try await client.likedTracks(accessToken: accessToken, pageURL: url, pageSize: 200)
        try Task.checkCancellation()
        guard sessionID == session else { throw CancellationError() }
        return page
    }

    private func validate(_ page: SoundCloudTrackPage, requestedURL: URL?, visited: inout Set<URL>) throws {
        if let next = page.nextURL, next == requestedURL || visited.contains(next) {
            throw SoundCloudError.invalidData
        }
        if let requestedURL { visited.insert(requestedURL) }
    }

    private func publishAndSave(accountID: String, session: UUID) async throws {
        // Local edits made while a page was in flight win over that page.
        cache.tracks.removeAll { unlikedTrackURNs.contains($0.urn) }
        let known = Set(cache.tracks.map(\.urn))
        let additions = tracks.filter { localChanges[$0.urn] != nil && !known.contains($0.urn) }
        cache.tracks.insert(contentsOf: additions, at: 0)
        tracks = cache.tracks
        try await store.save(cache, accountID: accountID)
        try Task.checkCancellation()
        guard sessionID == session else { throw CancellationError() }
    }

    func clear() {
        syncTask?.cancel()
        restoreTask?.cancel()
        syncTask = nil
        restoreTask = nil
        sessionID = UUID()
        accountID = nil
        cache = LikesCache()
        pendingLikes = [:]
        updatedLikeCounts = [:]
        localChanges = [:]
        unlikedTrackURNs = []
        isLoading = false
        tracks = []
        errorMessage = nil
    }
}
