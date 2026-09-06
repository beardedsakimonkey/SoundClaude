import Foundation

@MainActor
final class PlaylistsController: ObservableObject {
    @Published private(set) var playlists: [SoundCloudPlaylist] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let client: SoundCloudClient
    private let auth: AuthController
    private var nextPageURL: URL?
    private var hasLoaded = false
    private var loadedPageURLs: Set<URL> = []
    private var sessionID = UUID()

    init(client: SoundCloudClient, auth: AuthController) {
        self.client = client
        self.auth = auth
    }

    func load() async {
        guard !isLoading, !hasLoaded || nextPageURL != nil else { return }
        let requestSessionID = sessionID
        isLoading = true
        errorMessage = nil
        defer {
            if sessionID == requestSessionID { isLoading = false }
        }
        do {
            repeat {
                let accessToken = try await auth.validAccessToken()
                try Task.checkCancellation()
                guard sessionID == requestSessionID else { return }
                let pageURL = nextPageURL
                let page = try await client.playlists(accessToken: accessToken, pageURL: pageURL)
                try Task.checkCancellation()
                guard sessionID == requestSessionID else { return }
                if let nextURL = page.nextURL,
                   nextURL == pageURL || loadedPageURLs.contains(nextURL) {
                    throw SoundCloudError.invalidData
                }
                var knownURNs = Set(playlists.map(\.urn))
                playlists.append(contentsOf: page.playlists.filter {
                    knownURNs.insert($0.urn).inserted
                })
                if let pageURL { loadedPageURLs.insert(pageURL) }
                nextPageURL = page.nextURL
                hasLoaded = true
            } while nextPageURL != nil
        } catch {
            guard sessionID == requestSessionID, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        sessionID = UUID()
        playlists = []
        nextPageURL = nil
        loadedPageURLs = []
        hasLoaded = false
        isLoading = false
        errorMessage = nil
    }
}
