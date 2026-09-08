import Combine
import Foundation

@MainActor
final class PlaylistsController: ObservableObject {
    @Published private(set) var cache = PlaylistsCache()
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var loadingPlaylistURNs: Set<String> = []
    @Published private(set) var playlistErrors: [String: String] = [:]

    var playlists: [SoundCloudPlaylist] { cache.playlists }

    private let client: SoundCloudClient
    private let auth: AuthController
    private let store: PlaylistsCacheStore
    private var accountID: String?
    private var sessionID = UUID()
    private var restoreTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var playlistTasks: [String: Task<Void, Never>] = [:]

    init(client: SoundCloudClient, auth: AuthController,
         store: PlaylistsCacheStore = PlaylistsCacheStore()) {
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
            // A missing or damaged file is rebuilt from the API.
            let saved = try? await store.load(accountID: id)
            guard sessionID == session else { return }
            cache = saved ?? PlaylistsCache()
            restoreTask = nil
        }
        restoreTask = task
        await task.value
    }

    func load() async {
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
                let hadCompleteList = cache.hasLoadedList
                let previousPlaylistURNs = Set(cache.playlists.map(\.urn))
                var refreshed: [SoundCloudPlaylist] = []
                var known = Set<String>()
                var url: URL?
                var visited = Set<URL>()
                repeat {
                    let token = try await accessToken(session: session)
                    let page = try await client.playlists(accessToken: token, pageURL: url)
                    try checkSession(session)
                    try validate(next: page.nextURL, requested: url, visited: &visited)
                    refreshed.append(contentsOf: page.playlists.filter { known.insert($0.urn).inserted })
                    // Keep the complete old list visible until refresh confirms removals.
                    if !hadCompleteList || page.nextURL == nil {
                        cache.playlists = refreshed
                        cache.hasLoadedList = page.nextURL == nil
                        if cache.hasLoadedList {
                            // Remove deleted library playlists, but keep playlists opened from the feed.
                            cache.contents = cache.contents.filter {
                                known.contains($0.key) || !previousPlaylistURNs.contains($0.key)
                            }
                        }
                        try await save(accountID: accountID, session: session)
                    }
                    url = page.nextURL
                    if url != nil { try await Task.sleep(for: .milliseconds(350)) }
                } while url != nil
            } catch {
                if sessionID == session, !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                }
            }
        }
        syncTask = task
        await task.value
    }

    /// Restore immediately, then refresh all pages to detect edits and reordering.
    func loadPlaylist(_ playlist: SoundCloudPlaylist) async {
        await restoreCache()
        let urn = playlist.urn
        if let task = playlistTasks[urn] {
            await task.value
            return
        }
        guard let accountID else { return }
        let session = sessionID
        loadingPlaylistURNs.insert(urn)
        playlistErrors.removeValue(forKey: urn)
        let task = Task { @MainActor in
            defer {
                if sessionID == session {
                    playlistTasks.removeValue(forKey: urn)
                    loadingPlaylistURNs.remove(urn)
                }
            }
            do {
                let hadCompleteContents = cache.contents[urn]?.isComplete == true
                let token = try await accessToken(session: session)
                let details = try await client.playlist(urn: urn, accessToken: token)
                try checkSession(session)
                var refreshed = PlaylistContents(playlist: details)
                var visited = Set<URL>()
                repeat {
                    let url = refreshed.nextPageURL
                    let token = try await accessToken(session: session)
                    let page = try await client.playlistTracks(urn: urn, accessToken: token, pageURL: url)
                    try checkSession(session)
                    try validate(next: page.nextURL, requested: url, visited: &visited)
                    refreshed.append(page)
                    // Save each initial page; a failed refresh retains the complete snapshot.
                    if !hadCompleteContents || refreshed.isComplete {
                        cache.contents[urn] = refreshed
                        if let index = cache.playlists.firstIndex(where: { $0.urn == urn }) {
                            cache.playlists[index] = details
                        }
                        try await save(accountID: accountID, session: session)
                    }
                    if refreshed.nextPageURL != nil { try await Task.sleep(for: .milliseconds(350)) }
                } while refreshed.nextPageURL != nil
            } catch {
                if sessionID == session, !(error is CancellationError) {
                    playlistErrors[urn] = error.localizedDescription
                }
            }
        }
        playlistTasks[urn] = task
        await task.value
    }

    private func accessToken(session: UUID) async throws -> String {
        try checkSession(session)
        let token = try await auth.validAccessToken()
        try checkSession(session)
        return token
    }

    private func checkSession(_ session: UUID) throws {
        try Task.checkCancellation()
        guard sessionID == session else { throw CancellationError() }
    }

    private func validate(next: URL?, requested: URL?, visited: inout Set<URL>) throws {
        if let next, next == requested || visited.contains(next) {
            throw SoundCloudError.invalidData
        }
        if let requested { visited.insert(requested) }
    }

    private func save(accountID: String, session: UUID) async throws {
        try await store.save(cache, accountID: accountID)
        try checkSession(session)
    }

    func clear() {
        syncTask?.cancel()
        restoreTask?.cancel()
        for task in playlistTasks.values { task.cancel() }
        syncTask = nil
        restoreTask = nil
        playlistTasks = [:]
        sessionID = UUID()
        accountID = nil
        cache = PlaylistsCache()
        isLoading = false
        errorMessage = nil
        loadingPlaylistURNs = []
        playlistErrors = [:]
    }
}
