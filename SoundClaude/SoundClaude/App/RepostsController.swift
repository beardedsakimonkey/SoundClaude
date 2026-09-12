import Combine
import Foundation

@MainActor
final class RepostsController: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var updatingTrackURNs: Set<String> = []
    @Published private var repostedURNs: Set<String> = []
    @Published private var updatedCounts: [String: Int] = [:]

    private let client: SoundCloudClient
    private let auth: AuthController
    private var hasLoaded = false
    private var sessionID = UUID()
    private var loadTask: Task<Void, Error>?

    init(client: SoundCloudClient, auth: AuthController) {
        self.client = client
        self.auth = auth
    }

    func isReposted(_ track: SoundCloudTrack) -> Bool {
        repostedURNs.contains(track.urn)
    }

    func repostCount(for track: SoundCloudTrack) -> Int? {
        updatedCounts[track.urn] ?? track.repostsCount
    }

    func load() async throws {
        if let loadTask { return try await loadTask.value }
        guard !hasLoaded else { return }
        let session = sessionID
        isLoading = true
        let task = Task { @MainActor in
            defer {
                if sessionID == session {
                    isLoading = false
                    loadTask = nil
                }
            }
            var urns = Set<String>()
            var nextURL: URL?
            var visited = Set<URL>()
            repeat {
                try Task.checkCancellation()
                let token = try await auth.validAccessToken()
                guard sessionID == session else { throw CancellationError() }
                let page = try await client.repostedTracks(accessToken: token, pageURL: nextURL)
                try Task.checkCancellation()
                guard sessionID == session else { throw CancellationError() }
                urns.formUnion(page.tracks.map(\.urn))
                if let next = page.nextURL, !visited.insert(next).inserted {
                    throw SoundCloudError.invalidData
                }
                nextURL = page.nextURL
            } while nextURL != nil
            repostedURNs = urns
            hasLoaded = true
        }
        loadTask = task
        try await task.value
    }

    func toggleRepost(_ track: SoundCloudTrack) async throws {
        let session = sessionID
        guard updatingTrackURNs.insert(track.urn).inserted else { return }
        defer {
            if sessionID == session { updatingTrackURNs.remove(track.urn) }
        }
        // Load every page before deciding whether to add or remove a repost.
        try await load()
        guard sessionID == session else { throw CancellationError() }
        let shouldRepost = !isReposted(track)
        let token = try await auth.validAccessToken()
        guard sessionID == session else { throw CancellationError() }
        try await client.setTrackReposted(urn: track.urn, isReposted: shouldRepost, accessToken: token)
        guard sessionID == session else { throw CancellationError() }
        if let count = repostCount(for: track) {
            updatedCounts[track.urn] = max(0, count + (shouldRepost ? 1 : -1))
        }
        if shouldRepost {
            repostedURNs.insert(track.urn)
        } else {
            repostedURNs.remove(track.urn)
        }
    }

    func clear() {
        sessionID = UUID()
        loadTask?.cancel()
        loadTask = nil
        hasLoaded = false
        isLoading = false
        repostedURNs = []
        updatedCounts = [:]
        updatingTrackURNs = []
    }
}
