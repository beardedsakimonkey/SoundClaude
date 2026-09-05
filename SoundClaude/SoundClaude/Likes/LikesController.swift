import Foundation

@MainActor
final class LikesController: ObservableObject {
    @Published private(set) var tracks: [SoundCloudTrack] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isLoadingAll = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var updatingTrackURNs: Set<String> = []

    private let client: SoundCloudClient
    private let auth: AuthController
    private var nextPageURL: URL?
    private var unlikedTrackURNs: Set<String> = []
    private var sessionID = UUID()
    private var hasLoadedFirstPage = false
    private var pageTask: Task<Void, Error>?
    private var allTracksTask: Task<Void, Error>?
    private var allTracksRequestID: UUID?

    var canLoadMore: Bool { nextPageURL != nil }

    init(client: SoundCloudClient, auth: AuthController) {
        self.client = client
        self.auth = auth
    }

    func isLiked(_ track: SoundCloudTrack) -> Bool {
        tracks.contains { $0.urn == track.urn }
    }

    func toggleLike(_ track: SoundCloudTrack) async throws {
        guard updatingTrackURNs.insert(track.urn).inserted else { return }
        let requestSessionID = sessionID
        let shouldLike = !isLiked(track)
        defer {
            if sessionID == requestSessionID {
                updatingTrackURNs.remove(track.urn)
            }
        }

        let accessToken = try await auth.validAccessToken()
        guard sessionID == requestSessionID else { return }
        try await client.setTrackLiked(
            urn: track.urn,
            isLiked: shouldLike,
            accessToken: accessToken
        )
        guard sessionID == requestSessionID else { return }
        if shouldLike {
            unlikedTrackURNs.remove(track.urn)
            if !isLiked(track) {
                tracks.insert(track, at: 0)
            }
        } else {
            unlikedTrackURNs.insert(track.urn)
            tracks.removeAll { $0.urn == track.urn }
        }
    }

    func loadLikedTracks() async {
        guard pageTask == nil, !isLoadingAll else { return }
        try? await loadPage(refresh: true)
    }

    func loadMore() async {
        guard pageTask == nil, !isLoadingAll, canLoadMore else { return }
        try? await loadPage()
    }

    /// Fetch only metadata. Audio, artwork, and waveforms load on demand.
    func loadAllTracks() async throws {
        if let allTracksTask {
            try await allTracksTask.value
            return
        }
        let requestID = UUID()
        let requestSessionID = sessionID
        allTracksRequestID = requestID
        isLoadingAll = true
        let task = Task { @MainActor in
            defer {
                if allTracksRequestID == requestID {
                    allTracksTask = nil
                    allTracksRequestID = nil
                    isLoadingAll = false
                }
            }
            while true {
                try Task.checkCancellation()
                guard sessionID == requestSessionID else { throw CancellationError() }
                if let pageTask {
                    // Share a request already started by the list.
                    try await pageTask.value
                } else if !hasLoadedFirstPage || canLoadMore {
                    try await loadPage(pageSize: 200)
                } else {
                    return
                }
            }
        }
        allTracksTask = task
        try await task.value
    }

    func cancelLoadingAllTracks() {
        allTracksTask?.cancel()
        allTracksTask = nil
        allTracksRequestID = nil
        isLoadingAll = false
    }

    private func loadPage(refresh: Bool = false, pageSize: Int? = nil) async throws {
        if let pageTask {
            try await pageTask.value
            return
        }
        let requestSessionID = sessionID
        let isFirstPage = refresh || !hasLoadedFirstPage
        let pageURL = isFirstPage ? nil : nextPageURL
        isLoading = isFirstPage
        isLoadingMore = !isFirstPage
        errorMessage = nil
        let task = Task { @MainActor in
            defer {
                if sessionID == requestSessionID {
                    pageTask = nil
                    isLoading = false
                    isLoadingMore = false
                }
            }
            do {
                let accessToken = try await auth.validAccessToken()
                try Task.checkCancellation()
                let page = try await client.likedTracks(
                    accessToken: accessToken,
                    pageURL: pageURL,
                    pageSize: pageSize
                )
                try Task.checkCancellation()
                guard sessionID == requestSessionID else { throw CancellationError() }
                var knownURNs = isFirstPage ? Set<String>() : Set(tracks.map(\.urn))
                let addedTracks = page.tracks.filter {
                    !unlikedTrackURNs.contains($0.urn) && knownURNs.insert($0.urn).inserted
                }
                if isFirstPage {
                    tracks = addedTracks
                } else {
                    tracks.append(contentsOf: addedTracks)
                }
                hasLoadedFirstPage = true
                nextPageURL = page.nextURL
            } catch {
                if sessionID == requestSessionID, !Task.isCancelled,
                   !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                }
                throw error
            }
        }
        pageTask = task
        try await task.value
    }

    func clear() {
        cancelLoadingAllTracks()
        pageTask?.cancel()
        pageTask = nil
        sessionID = UUID()
        hasLoadedFirstPage = false
        updatingTrackURNs = []
        unlikedTrackURNs = []
        isLoading = false
        isLoadingMore = false
        tracks = []
        nextPageURL = nil
        errorMessage = nil
    }
}
