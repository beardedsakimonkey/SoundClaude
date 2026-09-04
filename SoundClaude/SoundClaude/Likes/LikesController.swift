import Foundation

@MainActor
final class LikesController: ObservableObject {
    @Published private(set) var tracks: [SoundCloudTrack] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?

    private let client: SoundCloudClient
    private let auth: AuthController
    private var nextPageURL: URL?

    var canLoadMore: Bool { nextPageURL != nil }

    init(client: SoundCloudClient, auth: AuthController) {
        self.client = client
        self.auth = auth
    }

    func loadLikedTracks() async {
        guard !isLoading, !isLoadingMore else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let accessToken = try await auth.validAccessToken()
            let page = try await client.likedTracks(accessToken: accessToken)
            tracks = page.tracks
            nextPageURL = page.nextURL
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard !isLoading,
              !isLoadingMore,
              let pageURL = nextPageURL else { return }
        isLoadingMore = true
        errorMessage = nil
        defer { isLoadingMore = false }
        do {
            let accessToken = try await auth.validAccessToken()
            let page = try await client.likedTracks(
                accessToken: accessToken,
                pageURL: pageURL
            )
            var knownURNs = Set(tracks.map(\.urn))
            tracks.append(contentsOf: page.tracks.filter {
                knownURNs.insert($0.urn).inserted
            })
            nextPageURL = page.nextURL
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        tracks = []
        nextPageURL = nil
        errorMessage = nil
    }
}
