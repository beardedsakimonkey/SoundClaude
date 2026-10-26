import Combine
import Observation
import Foundation

@MainActor
@Observable
final class LikesController {
    private(set) var tracks: [SoundCloudTrack] = [] {
        didSet {
            likedTrackURNs = Set(tracks.map(\.urn))
            refreshTrackStates()
            tracksSubject.send(tracks)
        }
    }
    // Rows query this frequently; do not scan the full library for every row.
    @ObservationIgnored private var likedTrackURNs: Set<String> = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var pendingLikes: [String: Bool] = [:] {
        didSet { refreshTrackStates() }
    }
    @ObservationIgnored private var updatedLikeCounts: [String: Int] = [:] {
        didSet { refreshTrackStates() }
    }

    private(set) var likedStations: [SoundCloudStationLikePage.Station] = [] {
        didSet { likedStationURNs = Set(likedStations.map(\.urn)) }
    }
    private(set) var likedStationURNs: Set<String> = []
    private(set) var stationLikesErrorMessage: String?
    private(set) var updatingStationURNs: Set<String> = []
    private(set) var isLoadingStationLikes = false
    private(set) var hasLoadedStationLikes = false
    private var stationLikesTask: Task<Void, Error>?

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

    // Queue persistence still needs a stream of completed library changes.
    @ObservationIgnored private let tracksSubject = CurrentValueSubject<[SoundCloudTrack], Never>([])
    var tracksPublisher: AnyPublisher<[SoundCloudTrack], Never> { tracksSubject.eraseToAnyPublisher() }

    // Each track has its own observation scope; dictionary reads would observe all tracks.
    @Observable
    final class TrackState {
        var isLiked = false
        var isUpdating = false
        var updatedCount: Int?
    }
    @ObservationIgnored private var trackStates: [String: TrackState] = [:]

    private func state(for urn: String) -> TrackState {
        if let state = trackStates[urn] { return state }
        let state = TrackState()
        update(state, urn: urn)
        trackStates[urn] = state
        return state
    }

    private func update(_ state: TrackState, urn: String) {
        state.isLiked = pendingLikes[urn] ?? likedTrackURNs.contains(urn)
        state.isUpdating = pendingLikes[urn] != nil
        state.updatedCount = updatedLikeCounts[urn]
    }

    private func refreshTrackStates() {
        for (urn, state) in trackStates { update(state, urn: urn) }
    }

    func isUpdating(trackURN: String) -> Bool { state(for: trackURN).isUpdating }

    var canLoadMore: Bool { cache.nextPageURL != nil }
    var isLoadingMore: Bool { isLoading && !tracks.isEmpty }
    var updatingTrackURNs: Set<String> { Set(pendingLikes.keys) }

    init(client: SoundCloudClient, auth: AuthController, store: LikesCacheStore = LikesCacheStore()) {
        self.client = client
        self.auth = auth
        self.store = store
        if case let .signedIn(user) = auth.state {
            let id = user.urn ?? user.permalinkURL.absoluteString
            likedStations = (try? store.loadStationsForLaunch(accountID: id)) ?? []
            likedStationURNs = Set(likedStations.map(\.urn))
        }
    }

    func restoreCache() async {
        let interval = LaunchMetrics.begin("Likes cache restore")
        defer { LaunchMetrics.end(interval) }
        if let restoreTask {
            await restoreTask.value
            return
        }
        guard case let .signedIn(user) = auth.state else { return }
        let id = user.urn ?? user.permalinkURL.absoluteString
        guard accountID != id else { return }
        // A fresh controller is already empty. Publishing another empty list here
        // would erase the queue's saved shuffle order before its cache arrives.
        if accountID != nil { clear() }
        accountID = id
        let session = sessionID
        let task = Task { @MainActor in
            // A missing or damaged cache can be rebuilt from the API.
            let saved = try? await store.load(accountID: id)
            let savedStations = try? await store.loadStations(accountID: id)
            guard sessionID == session else { return }
            LaunchMetrics.measure("Likes cache publish") {
                cache = saved ?? LikesCache()
                tracks = cache.tracks
                // Keep the session load flag false so cached stations refresh on entry.
                likedStations = savedStations ?? []
            }
            restoreTask = nil
        }
        restoreTask = task
        await task.value
    }

    func isLiked(_ track: SoundCloudTrack) -> Bool {
        state(for: track.urn).isLiked
    }

    func loadStationLikes() async throws {
        let interval = LaunchMetrics.begin("Station likes sync")
        defer { LaunchMetrics.end(interval) }
        await restoreCache()
        if let stationLikesTask {
            try await stationLikesTask.value
            return
        }
        guard let accountID, !hasLoadedStationLikes else { return }
        let session = sessionID
        isLoadingStationLikes = true
        stationLikesErrorMessage = nil
        let task = Task { @MainActor in
            defer {
                if sessionID == session {
                    stationLikesTask = nil
                    isLoadingStationLikes = false
                }
            }
            var urns = Set<String>()
            var stations: [SoundCloudStationLikePage.Station] = []
            var url: URL?
            var visited = Set<URL>()
            repeat {
                let token = try await auth.validAccessToken()
                try Task.checkCancellation()
                guard sessionID == session else { throw CancellationError() }
                let page = try await client.likedStations(accessToken: token, pageURL: url)
                try Task.checkCancellation()
                guard sessionID == session else { throw CancellationError() }
                if let next = page.nextURL, next == url || visited.contains(next) {
                    throw SoundCloudError.invalidData
                }
                if let url { visited.insert(url) }
                stations.append(contentsOf: page.collection.filter { urns.insert($0.urn).inserted })
                url = page.nextURL
            } while url != nil
            likedStations = stations
            try await store.saveStations(stations, accountID: accountID)
            guard sessionID == session else { throw CancellationError() }
            hasLoadedStationLikes = true
        }
        stationLikesTask = task
        do {
            try await task.value
        } catch {
            if sessionID == session, !(error is CancellationError) {
                stationLikesErrorMessage = error.localizedDescription
            }
            throw error
        }
    }

    func toggleStationLike(urn: String, title: String? = nil) async throws {
        try await loadStationLikes()
        guard let accountID, !updatingStationURNs.contains(urn) else { return }
        let session = sessionID
        let shouldLike = !likedStationURNs.contains(urn)
        updatingStationURNs.insert(urn)
        defer {
            if sessionID == session { updatingStationURNs.remove(urn) }
        }
        let token = try await auth.validAccessToken()
        guard sessionID == session else { throw CancellationError() }
        try await client.setPlaylistLiked(urn: urn, isLiked: shouldLike, accessToken: token)
        guard sessionID == session else { throw CancellationError() }
        if shouldLike {
            likedStations.insert(.init(urn: urn, title: title), at: 0)
        } else {
            likedStations.removeAll { $0.urn == urn }
        }
        try await store.saveStations(likedStations, accountID: accountID)
    }

    func likeCount(for track: SoundCloudTrack) -> Int? {
        state(for: track.urn).updatedCount ?? track.likesCount
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
        let interval = LaunchMetrics.begin("Likes sync")
        defer { LaunchMetrics.end(interval) }
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
        stationLikesTask?.cancel()
        stationLikesTask = nil
        likedStations = []
        stationLikesErrorMessage = nil
        updatingStationURNs = []
        hasLoadedStationLikes = false
        isLoadingStationLikes = false
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
