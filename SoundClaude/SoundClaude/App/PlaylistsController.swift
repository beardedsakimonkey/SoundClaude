import Combine
import Foundation
import Observation

@MainActor
final class PlaylistsController: ObservableObject {
    @Published private(set) var cache = PlaylistsCache() {
        didSet { updateCardStates() }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var loadingPlaylistURNs: Set<String> = [] {
        didSet { updateCardStates() }
    }
    @Published private(set) var playlistErrors: [String: String] = [:] {
        didSet { updateCardStates() }
    }
    @Published private(set) var likedPlaylists: [SoundCloudPlaylist] = []
    @Published private(set) var isLoadingLikes = false
    @Published private(set) var hasLoadedLikes = false
    @Published private(set) var likesErrorMessage: String?
    @Published private(set) var updatingLikeURNs: Set<String> = []

    @Published private(set) var updatingPlaylistURNs: Set<String> = []

    var playlists: [SoundCloudPlaylist] { cache.playlists }
    var likedPlaylistURNs: Set<String> { Set(likedPlaylists.map(\.urn)) }

    // Cards must not subscribe to changes from other playlists in a lazy list.
    private var cardStates: [String: PlaylistCardState] = [:]

    func cardState(for urn: String) -> PlaylistCardState {
        if let state = cardStates[urn] { return state }
        let state = PlaylistCardState()
        updateCardState(state, urn: urn)
        cardStates[urn] = state
        return state
    }

    private func updateCardStates() {
        for (urn, state) in cardStates { updateCardState(state, urn: urn) }
    }

    private func updateCardState(_ state: PlaylistCardState, urn: String) {
        let contents = cache.contents[urn] ?? previews[urn]
        let isLoading = loadingPlaylistURNs.contains(urn)
        let errorMessage = playlistErrors[urn]
        if state.contents != contents { state.contents = contents }
        if state.isLoading != isLoading { state.isLoading = isLoading }
        if state.errorMessage != errorMessage { state.errorMessage = errorMessage }
    }

    func artworkURL(for playlist: SoundCloudPlaylist) -> URL? {
        let contents = cache.contents[playlist.urn]
        return contents?.playlist.artworkURL ?? playlist.artworkURL
            ?? contents?.tracks.first(where: { $0.displayArtworkURL != nil })?.displayArtworkURL
            ?? cache.artworkURLs?[playlist.urn]
    }

    /// Resolve track-based covers without retaining full track lists.
    func loadArtwork(for playlist: SoundCloudPlaylist) async {
        await restoreCache()
        guard artworkURL(for: playlist) == nil, let accountID else { return }
        let session = sessionID
        let saved = try? await store.loadContents(urn: playlist.urn, accountID: accountID)
        guard sessionID == session, !Task.isCancelled else { return }
        var url = saved?.playlist.artworkURL
            ?? saved?.tracks.first(where: { $0.displayArtworkURL != nil })?.displayArtworkURL
        if url == nil {
            await loadPreview(playlist)
            guard sessionID == session, !Task.isCancelled else { return }
            url = previews[playlist.urn]?.tracks.first(where: { $0.displayArtworkURL != nil })?.displayArtworkURL
        }
        guard let url else { return }
        if cache.artworkURLs == nil { cache.artworkURLs = [:] }
        cache.artworkURLs?[playlist.urn] = url
        try? await save(accountID: accountID, session: session)
    }

    // Feed previews never enter the persistent playlist cache.
    private var previews: [String: PlaylistContents] = [:]
    private var previewOrder: [String] = []
    private var previewTasks: [String: Task<Void, Never>] = [:]

    func loadPreview(_ playlist: SoundCloudPlaylist) async {
        await restoreCache()
        let urn = playlist.urn
        if let task = playlistTasks[urn] { await task.value }
        if cache.contents[urn] != nil { return }
        if previews[urn] != nil {
            previewOrder.removeAll { $0 == urn }
            previewOrder.append(urn)
            return
        }
        if let task = previewTasks[urn] { await task.value; return }
        guard accountID != nil else { return }
        let session = sessionID
        loadingPlaylistURNs.insert(urn)
        playlistErrors.removeValue(forKey: urn)
        let task = Task { @MainActor in
            defer {
                if sessionID == session {
                    previewTasks.removeValue(forKey: urn)
                    loadingPlaylistURNs.remove(urn)
                }
            }
            do {
                let token = try await accessToken(session: session)
                var preview = PlaylistContents(playlist: playlist)
                if playlist.isSystemPlaylist {
                    let station = try await client.station(urn: urn, accessToken: token)
                    preview.tracks = station.tracks
                    preview.hasLoadedPage = true
                } else {
                    let page = try await client.playlistTracks(
                        urn: urn, accessToken: token, pageURL: nil
                    )
                    preview.append(page)
                    // Keep the whole page so a playback queue can resume at
                    // nextPageURL without skipping tracks hidden by the card.
                }
                try checkSession(session)
                previews[urn] = preview
                previewOrder.append(urn)
                while previewOrder.count > 40 {
                    previews.removeValue(forKey: previewOrder.removeFirst())
                }
                updateCardStates()
            } catch {
                if sessionID == session, !(error is CancellationError) {
                    playlistErrors[urn] = error.localizedDescription
                }
            }
        }
        previewTasks[urn] = task
        await task.value
    }

    private let client: SoundCloudClient
    private let auth: AuthController
    private let store: PlaylistsCacheStore
    private var accountID: String?
    private var hasRestoredList = false
    private var sessionID = UUID()
    private var restoreTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var playlistTasks: [String: Task<Void, Never>] = [:]
    private var likesTask: Task<Void, Never>?

    init(client: SoundCloudClient, auth: AuthController,
         store: PlaylistsCacheStore = PlaylistsCacheStore()) {
        self.client = client
        self.auth = auth
        self.store = store
        if case let .signedIn(user) = auth.state {
            let id = user.urn ?? user.permalinkURL.absoluteString
            cache = (try? store.loadForLaunch(accountID: id)) ?? PlaylistsCache()
            accountID = id
        }
    }

    func restoreCache() async {
        let interval = LaunchMetrics.begin("Playlist cache restore")
        defer { LaunchMetrics.end(interval) }
        if let restoreTask {
            await restoreTask.value
            return
        }
        guard case let .signedIn(user) = auth.state else { return }
        let id = user.urn ?? user.permalinkURL.absoluteString
        guard accountID != id || !hasRestoredList else { return }
        if accountID != id { clear() }
        accountID = id
        let session = sessionID
        let task = Task { @MainActor in
            // A missing or damaged file is rebuilt from the API.
            try? await store.prune(accountID: id)
            let saved = try? store.loadForLaunch(accountID: id)
            guard sessionID == session else { return }
            LaunchMetrics.measure("Playlist cache publish") {
                if let saved { cache = saved }
                hasRestoredList = true
            }
            restoreTask = nil
        }
        restoreTask = task
        await task.value
    }

    func restoreContents(urn: String) async {
        await restoreCache()
        guard cache.contents[urn] == nil, let accountID else { return }
        let session = sessionID
        let saved = try? await store.loadContents(urn: urn, accountID: accountID)
        guard sessionID == session, cache.contents[urn] == nil else { return }
        if let saved { cache.contents[urn] = saved }
    }

    func load() async {
        let interval = LaunchMetrics.begin("Playlist sync")
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

    func createPlaylist(title: String, description: String, isPrivate: Bool, artwork: PlaylistArtwork? = nil) async throws -> SoundCloudPlaylist {
        await restoreCache()
        let session = sessionID
        guard let accountID else { throw CancellationError() }
        let token = try await accessToken(session: session)
        let playlist = try await client.createPlaylist(
            title: title, description: description, isPrivate: isPrivate, artwork: artwork, accessToken: token
        )
        try checkSession(session)
        // Finish any list refresh before inserting so it cannot erase the new playlist.
        if let syncTask { await syncTask.value }
        try checkSession(session)
        cache.playlists.removeAll { $0.urn == playlist.urn }
        cache.playlists.insert(playlist, at: 0)
        cache.contents[playlist.urn] = PlaylistContents(playlist: playlist, hasLoadedPage: true)
        // Creation has succeeded remotely; a disk failure must not invite a duplicate POST.
        try? await save(accountID: accountID, session: session)
        try checkSession(session)
        return playlist
    }

    func updatePlaylist(
        _ playlist: SoundCloudPlaylist, title: String, description: String, isPrivate: Bool
    ) async throws -> SoundCloudPlaylist {
        await restoreContents(urn: playlist.urn)
        let session = sessionID
        guard let accountID else { throw CancellationError() }
        guard case let .signedIn(user) = auth.state,
              playlist.owner.urn == user.urn && user.urn != nil
                || playlist.owner.permalinkURL == user.permalinkURL else {
            throw SoundCloudError.invalidData
        }
        guard updatingPlaylistURNs.insert(playlist.urn).inserted else { throw SoundCloudError.invalidData }
        defer { if sessionID == session { updatingPlaylistURNs.remove(playlist.urn) } }
        let token = try await accessToken(session: session)
        let updated = try await client.updatePlaylist(
            urn: playlist.urn, title: title, description: description,
            isPrivate: isPrivate, accessToken: token
        )
        try checkSession(session)
        // Let existing refreshes finish before publishing the saved metadata.
        if let syncTask { await syncTask.value }
        if let task = playlistTasks[playlist.urn] { await task.value }
        if let likesTask { await likesTask.value }
        try checkSession(session)
        if let index = cache.playlists.firstIndex(where: { $0.urn == playlist.urn }) {
            cache.playlists[index] = updated
        }
        var contents = cache.contents[playlist.urn] ?? PlaylistContents(playlist: updated)
        contents.playlist = updated
        cache.contents[playlist.urn] = contents
        if let index = likedPlaylists.firstIndex(where: { $0.urn == playlist.urn }) {
            likedPlaylists[index] = updated
        }
        // The remote save succeeded even if the disk cache cannot be written.
        try? await save(accountID: accountID, session: session)
        try checkSession(session)
        return updated
    }

    func addTrack(_ track: SoundCloudTrack, to playlist: SoundCloudPlaylist) async throws {
        try await updateTrack(track, in: playlist, removing: false)
    }

    func removeTrack(_ track: SoundCloudTrack, from playlist: SoundCloudPlaylist) async throws {
        try await updateTrack(track, in: playlist, removing: true)
    }

    private func updateTrack(_ track: SoundCloudTrack, in playlist: SoundCloudPlaylist, removing: Bool) async throws {
        await restoreCache()
        let session = sessionID
        guard case let .signedIn(user) = auth.state,
              playlist.owner.urn == user.urn && user.urn != nil
                || playlist.owner.permalinkURL == user.permalinkURL else {
            throw SoundCloudError.invalidData
        }
        guard updatingPlaylistURNs.insert(playlist.urn).inserted else { throw SoundCloudError.invalidData }
        defer {
            if sessionID == session { updatingPlaylistURNs.remove(playlist.urn) }
        }
        let token = try await accessToken(session: session)
        if removing {
            try await client.removeTrackFromPlaylist(
                trackURN: track.urn, playlistURN: playlist.urn, accessToken: token
            )
        } else {
            try await client.addTrackToPlaylist(
                trackURN: track.urn, playlistURN: playlist.urn, accessToken: token
            )
        }
        try checkSession(session)
        if removing {
            trackURNs[playlist.urn]?.remove(track.urn)
        } else {
            trackURNs[playlist.urn]?.insert(track.urn)
        }
        if let syncTask { await syncTask.value }
        if let task = playlistTasks[playlist.urn] { await task.value }
        try checkSession(session)
        await loadPlaylist(playlist)
    }

    // Membership scans keep only track URNs, not full track lists.
    private var trackURNs: [String: Set<String>] = [:]
    private var trackURNTasks: [String: Task<Set<String>, Error>] = [:]

    func contains(_ track: SoundCloudTrack, in playlist: SoundCloudPlaylist) async throws -> Bool {
        try await trackURNs(in: playlist).contains(track.urn)
    }

    private func trackURNs(in playlist: SoundCloudPlaylist) async throws -> Set<String> {
        await restoreCache()
        let urn = playlist.urn
        if let task = playlistTasks[urn] { await task.value }
        if let contents = cache.contents[urn], contents.isComplete {
            return Set(contents.tracks.map(\.urn))
        }
        if let urns = trackURNs[urn] { return urns }
        if let task = trackURNTasks[urn] { return try await task.value }
        guard let accountID else { throw CancellationError() }
        let session = sessionID
        let task = Task { @MainActor in
            defer { if sessionID == session { trackURNTasks.removeValue(forKey: urn) } }
            if let saved = try? await store.loadContents(urn: urn, accountID: accountID), saved.isComplete {
                try checkSession(session)
                return Set(saved.tracks.map(\.urn))
            }
            var urns = Set<String>()
            var url: URL?
            var visited = Set<URL>()
            repeat {
                let token = try await accessToken(session: session)
                let page = try await client.playlistTracks(urn: urn, accessToken: token, pageURL: url)
                try checkSession(session)
                try validate(next: page.nextURL, requested: url, visited: &visited)
                urns.formUnion(page.tracks.map(\.urn))
                url = page.nextURL
                if url != nil { try await Task.sleep(for: .milliseconds(350)) }
            } while url != nil
            trackURNs[urn] = urns
            return urns
        }
        trackURNTasks[urn] = task
        return try await task.value
    }

    func deletePlaylist(_ playlist: SoundCloudPlaylist) async throws {
        await restoreCache()
        let session = sessionID
        guard let accountID else { throw CancellationError() }
        let token = try await accessToken(session: session)
        try await client.deletePlaylist(urn: playlist.urn, accessToken: token)
        try checkSession(session)
        // Finish existing refreshes before removing the playlist from the cache.
        if let syncTask { await syncTask.value }
        if let task = playlistTasks[playlist.urn] { await task.value }
        if let likesTask { await likesTask.value }
        try checkSession(session)
        cache.playlists.removeAll { $0.urn == playlist.urn }
        cache.contents.removeValue(forKey: playlist.urn)
        try? await store.removeContents(urn: playlist.urn, accountID: accountID)
        try checkSession(session)
        playlistErrors.removeValue(forKey: playlist.urn)
        likedPlaylists.removeAll { $0.urn == playlist.urn }
        // Deletion succeeded remotely; a disk failure must not invite another DELETE.
        try? await save(accountID: accountID, session: session)
        try checkSession(session)
    }

    /// Restore immediately, then refresh all pages to detect edits and reordering.
    func loadPlaylist(_ playlist: SoundCloudPlaylist) async {
        await restoreCache()
        let urn = playlist.urn
        if let preview = previewTasks[urn] { await preview.value }
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
                await restoreContents(urn: urn)
                try checkSession(session)
                let hadCompleteContents = cache.contents[urn]?.isComplete == true
                let token = try await accessToken(session: session)
                if playlist.isSystemPlaylist {
                    let contents = try await client.station(urn: urn, accessToken: token)
                    try checkSession(session)
                    cache.contents[urn] = PlaylistContents(
                        playlist: .systemPlaylist(urn: urn, title: playlist.title, contents: contents),
                        tracks: contents.tracks, hasLoadedPage: true
                    )
                    try await save(accountID: accountID, session: session)
                    return
                }
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
                        if let index = likedPlaylists.firstIndex(where: { $0.urn == urn }) {
                            likedPlaylists[index] = details
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

    func loadLikes() async {
        let interval = LaunchMetrics.begin("Playlist likes sync")
        defer { LaunchMetrics.end(interval) }
        await restoreCache()
        if let likesTask {
            await likesTask.value
            return
        }
        guard accountID != nil, !hasLoadedLikes else { return }
        let session = sessionID
        likesErrorMessage = nil
        isLoadingLikes = true
        let task = Task { @MainActor in
            defer {
                if sessionID == session {
                    likesTask = nil
                    isLoadingLikes = false
                }
            }
            do {
                var likedURNs: Set<String> = []
                var refreshed: [SoundCloudPlaylist] = []
                var url: URL?
                var visited: Set<URL> = []
                repeat {
                    let token = try await accessToken(session: session)
                    let page = try await client.likedPlaylists(accessToken: token, pageURL: url)
                    try checkSession(session)
                    try validate(next: page.nextURL, requested: url, visited: &visited)
                    refreshed.append(contentsOf: page.playlists.filter { likedURNs.insert($0.urn).inserted })
                    url = page.nextURL
                    if url != nil { try await Task.sleep(for: .milliseconds(350)) }
                } while url != nil
                likedPlaylists = refreshed
                hasLoadedLikes = true
            } catch {
                if sessionID == session, !(error is CancellationError) {
                    likesErrorMessage = error.localizedDescription
                }
            }
        }
        likesTask = task
        await task.value
    }

    func toggleLike(_ playlist: SoundCloudPlaylist) async throws {
        guard !playlist.isPrivate else { return }
        await loadLikes()
        guard hasLoadedLikes, updatingLikeURNs.insert(playlist.urn).inserted else { return }
        let session = sessionID
        defer { if sessionID == session { updatingLikeURNs.remove(playlist.urn) } }
        let shouldLike = !likedPlaylistURNs.contains(playlist.urn)
        let token = try await accessToken(session: session)
        try await client.setPlaylistLiked(urn: playlist.urn, isLiked: shouldLike, accessToken: token)
        try checkSession(session)
        if shouldLike {
            likedPlaylists.insert(playlist, at: 0)
        } else {
            likedPlaylists.removeAll { $0.urn == playlist.urn }
        }
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
        for task in previewTasks.values { task.cancel() }
        previewTasks = [:]
        previews = [:]
        previewOrder = []
        likesTask?.cancel()
        likesTask = nil
        likedPlaylists = []
        isLoadingLikes = false
        hasLoadedLikes = false
        likesErrorMessage = nil
        updatingLikeURNs = []
        syncTask?.cancel()
        restoreTask?.cancel()
        for task in playlistTasks.values { task.cancel() }
        for task in trackURNTasks.values { task.cancel() }
        trackURNTasks = [:]
        trackURNs = [:]
        syncTask = nil
        restoreTask = nil
        playlistTasks = [:]
        sessionID = UUID()
        accountID = nil
        hasRestoredList = false
        cache = PlaylistsCache()
        isLoading = false
        errorMessage = nil
        loadingPlaylistURNs = []
        playlistErrors = [:]
        updatingPlaylistURNs = []
    }
}

@MainActor
@Observable
final class PlaylistCardState {
    fileprivate(set) var contents: PlaylistContents?
    fileprivate(set) var isLoading = false
    fileprivate(set) var errorMessage: String?
}
