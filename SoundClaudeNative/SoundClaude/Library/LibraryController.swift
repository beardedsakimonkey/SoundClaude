import Foundation

@MainActor
final class LibraryController: ObservableObject {
    @Published private(set) var tracks: [SoundCloudTrack] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let client: SoundCloudClient
    private let auth: AuthController

    init(client: SoundCloudClient, auth: AuthController) {
        self.client = client
        self.auth = auth
    }

    func loadLikedTracks() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let accessToken = try await auth.validAccessToken()
            tracks = try await client.likedTracks(accessToken: accessToken)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        tracks = []
        errorMessage = nil
    }
}
