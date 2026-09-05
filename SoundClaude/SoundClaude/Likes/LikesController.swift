import Foundation

@MainActor
final class LikesController: ObservableObject {
    @Published private(set) var tracks: [SoundCloudTrack] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var updatingTrackURNs: Set<String> = []

    private let client: SoundCloudClient
    private let auth: AuthController
    private var nextPageURL: URL?
    private var unlikedTrackURNs: Set<String> = []
    private var sessionID = UUID()

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
        guard !isLoading, !isLoadingMore else { return }
        isLoading = true
        let requestSessionID = sessionID
        errorMessage = nil
        defer {
            if sessionID == requestSessionID { isLoading = false }
        }
        do {
            let accessToken = try await auth.validAccessToken()
            let page = try await client.likedTracks(accessToken: accessToken)
            guard sessionID == requestSessionID else { return }
            tracks = page.tracks.filter { !unlikedTrackURNs.contains($0.urn) }
            nextPageURL = page.nextURL
        } catch {
            guard sessionID == requestSessionID else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard !isLoading,
              !isLoadingMore,
              let pageURL = nextPageURL else { return }
        isLoadingMore = true
        let requestSessionID = sessionID
        errorMessage = nil
        defer {
            if sessionID == requestSessionID { isLoadingMore = false }
        }
        do {
            let accessToken = try await auth.validAccessToken()
            let page = try await client.likedTracks(
                accessToken: accessToken,
                pageURL: pageURL
            )
            guard sessionID == requestSessionID else { return }
            var knownURNs = Set(tracks.map(\.urn))
            tracks.append(contentsOf: page.tracks.filter {
                !unlikedTrackURNs.contains($0.urn)
                    && knownURNs.insert($0.urn).inserted
            })
            nextPageURL = page.nextURL
        } catch {
            guard sessionID == requestSessionID else { return }
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        sessionID = UUID()
        updatingTrackURNs = []
        unlikedTrackURNs = []
        isLoading = false
        isLoadingMore = false
        tracks = []
        nextPageURL = nil
        errorMessage = nil
    }
}
