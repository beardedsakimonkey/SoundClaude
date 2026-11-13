import AppKit
import Combine
import Observation

struct CachedArtistHeader {
    let artistURL: URL
    let artworkURL: URL
    let image: NSImage
}

struct ArtistFirstPages {
    var tracks: SoundCloudTrackPage?
    var reposts: SoundCloudTrackPage?
    var repostedPlaylists: SoundCloudPlaylistPage?
    var playlists: SoundCloudPlaylistPage?
    var likes: SoundCloudTrackPage?
    var likedPlaylists: SoundCloudPlaylistPage?
}

@MainActor
@Observable
final class AppModel {
    let analyzer: SpectrumAnalyzer
    let audioTap: AudioTapController
    let playback: PlaybackController
    let auth: AuthController
    let reposts: RepostsController
    let likes: LikesController
    let playlists: PlaylistsController
    let feed: FeedController
    let artworkLoader: ArtworkLoader
    let commentDrafts = TrackCommentDraftStore()

    private(set) var errorMessage: String?
    var likeErrorMessage: String?
    private(set) var currentTrackLikeEvents = 0
    /// The embedded soundcloud.com sign-in page, while it is open.
    private(set) var websiteLogin: WebsiteLogin?
    /// Progress of a copied-session import, which keeps the signed-out view up
    /// until the import button has shown its outcome.
    private(set) var sessionImportPhase: SessionImportPhase?
    /// Counts failed imports, so a retry that fails with the same message still registers.
    private(set) var importFailureCount = 0

    enum SessionImportPhase {
        case importing
        case succeeded
    }

    // Do not broadcast deferred history writes to every AppModel observer.
    private let history = HistoryState()
    var historyTracks: [SoundCloudTrack] { history.tracks }
    private let historyStore = HistoryStore()
    @ObservationIgnored private var historyAccountObservation: AnyCancellable?

    private let client: SoundCloudClient
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var playbackRequestID: UUID?
    @ObservationIgnored private var trackSelectionTask: Task<Void, Never>?
    @ObservationIgnored private var queuePrefetchTask: Task<Void, Never>?
    @ObservationIgnored private var shuffleQueueTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchedTrack: SoundCloudTrack?
    @ObservationIgnored private var likesObservation: AnyCancellable?
    @ObservationIgnored private var playlistsObservation: AnyCancellable?
    @ObservationIgnored private var followingTask: Task<Set<String>, Error>?
    @ObservationIgnored private var followingRequestID: UUID?
    @ObservationIgnored private var followingStatuses: [String: Bool] = [:]
    @ObservationIgnored private var hasStarted = false
    private(set) var queue = TrackQueue(source: .single, tracks: [])
    private let queueStore = TrackQueueStore()
    // These limits bound cache growth as liked-track pages load.
    private let trackDetailsCache = RequestCache<TrackCacheKey, SoundCloudTrackDetails>(
        name: "Track Details", countLimit: 100
    )
    private let waveformCache = RequestCache<NSURL, SoundCloudWaveform>(
        name: "Waveforms", countLimit: 50, totalCostLimit: 8 * 1_024 * 1_024,
        cost: { $0.samples.count * MemoryLayout<Int>.stride }
    )
    // The detail list and waveform markers both read the first comment page.
    private let firstCommentPageCache = RequestCache<TrackCacheKey, SoundCloudCommentPage>(name: "First Comment Pages", countLimit: 20)
    private let firstArtistCommentPageCache = RequestCache<NSURL, SoundCloudCommentPage>(name: "First Artist Comment Pages", countLimit: 20)
    private let firstRelatedTrackPageCache = RequestCache<NSString, SoundCloudTrackPage>(name: "First Related Track Pages", countLimit: 20)
    private let firstTrackPlaylistPageCache = RequestCache<NSString, SoundCloudPlaylistPage>(name: "First Track Playlist Pages", countLimit: 20)
    // The track page asks for only the few playlists it shows.
    private let trackPlaylistPreviewCache = RequestCache<NSString, SoundCloudPlaylistPage>(name: "Track Playlist Previews", countLimit: 20)
    // Artist pages open on any tab, so each tab's first page is cached separately.
    private let firstArtistTrackPageCache = RequestCache<NSString, SoundCloudTrackPage>(name: "First Artist Track Pages", countLimit: 20)
    private let firstArtistRepostPageCache = RequestCache<NSString, SoundCloudTrackPage>(name: "First Artist Repost Pages", countLimit: 20)
    private let firstArtistPlaylistRepostPageCache = RequestCache<NSString, SoundCloudPlaylistPage>(name: "First Artist Playlist Repost Pages", countLimit: 20)
    private let firstArtistPlaylistPageCache = RequestCache<NSString, SoundCloudPlaylistPage>(name: "First Artist Playlist Pages", countLimit: 20)
    private let firstArtistLikePageCache = RequestCache<NSString, SoundCloudTrackPage>(name: "First Artist Like Pages", countLimit: 20)
    private let firstArtistPlaylistLikePageCache = RequestCache<NSString, SoundCloudPlaylistPage>(name: "First Artist Playlist Like Pages", countLimit: 20)
    // Keep initial search pages across Back/Forward navigation without unbounded growth.
    private let firstSearchTrackPageCache = RequestCache<SearchTrackCacheKey, SoundCloudTrackPage>(name: "First Search Track Pages", countLimit: 20)
    private let firstSearchPlaylistPageCache = RequestCache<NSString, SoundCloudPlaylistPage>(name: "First Search Playlist Pages", countLimit: 20)
    private let firstSearchUserPageCache = RequestCache<NSString, SoundCloudUserPage>(name: "First Search User Pages", countLimit: 20)
    private let searchCategoryCache = MemoryCache<NSString, SearchCategory>(name: "Search Categories", countLimit: 100)
    private let searchSuggestionCache = RequestCache<NSString, SoundCloudSearchSuggestions>(name: "Search Suggestions", countLimit: 100)
    private let artistDetailsCache = RequestCache<NSURL, SoundCloudArtistDetails>(name: "Artist Details", countLimit: 100)
    private let artistWebProfilesCache = RequestCache<NSURL, [SoundCloudWebProfile]>(name: "Artist Web Profiles", countLimit: 100)
    private let relatedArtistsCache = RequestCache<NSURL, [SoundCloudUser]>(name: "Related Artists", countLimit: 100)
    // nil records an artist without a profile header, so it is not looked up again.
    private let artistHeaderCache = RequestCache<NSURL, CachedArtistHeader?>(name: "Artist Headers", countLimit: 10)
    var loadingStations: [String: SoundCloudStation] = [:]
    private let stationMetadataCache = RequestCache<NSString, RawSystemPlaylist>(name: "Station Metadata", countLimit: 10)
    private let stationCache = RequestCache<NSString, SoundCloudStation>(name: "Stations", countLimit: 10)

    init() {
        let initialization = LaunchMetrics.begin("Model initialization")
        defer { LaunchMetrics.end(initialization) }
        guard let analyzer = LaunchMetrics.measure("Spectrum analyzer setup", { SpectrumAnalyzer() }) else {
            fatalError("The fixed audio buffers could not be created.")
        }
        let websiteBridge = WebsiteBridge()
        let client = SoundCloudClient(
            configuration: SoundCloudConfiguration(),
            websiteTransport: { request in try await websiteBridge.send(request) }
        )
        let audioTap = AudioTapController(analyzer: analyzer)
        let playback = LaunchMetrics.measure("Player setup and saved session") {
            // Keep session saves and volume changes from invalidating @AppStorage views.
            PlaybackController(
                sessionDefaults: UserDefaults(suiteName: "com.tim.soundclaude.playback-session")!,
                volumeDefaults: UserDefaults(suiteName: "com.tim.soundclaude.playback-volume")!
            )
        }
        let auth = LaunchMetrics.measure("Auth setup and Keychain read") { AuthController(client: client) }
        let likes = LaunchMetrics.measure("Likes setup and station cache") { LikesController(client: client, auth: auth) }

        self.analyzer = analyzer
        self.client = client
        self.audioTap = audioTap
        self.playback = playback
        self.auth = auth
        self.likes = likes
        playback.isTrackLiked = { [weak likes] track in
            likes?.tracks.contains(where: { $0.urn == track.urn }) ?? false
        }
        reposts = RepostsController(client: client, auth: auth)
        playlists = LaunchMetrics.measure("Playlists setup and launch cache") { PlaylistsController(client: client, auth: auth) }
        feed = FeedController(client: client, auth: auth)
        artworkLoader = ArtworkLoader(client: client)
        queue = LaunchMetrics.measure("Queue restore") {
            queueStore.restore(
                currentTrack: playback.currentTrack,
                shuffleEnabled: playback.isShuffleEnabled
            )
        }

        playback.onNeedsSource = { [weak self] track, requestID in
            guard let self else { return }
            playbackRequestID = requestID
            playbackTask = Task { @MainActor [weak self] in
                guard let self, playbackRequestID == requestID, !Task.isCancelled else { return }
                await resolvePlayback(track, requestID: requestID)
            }
        }
        playback.onReadyToPlay = { [weak audioTap] in
            Task { @MainActor in
                await audioTap?.startForCurrentProcess()
            }
        }
        playback.onTrackStarted = { [weak self] track in
            guard let self, case let .signedIn(user) = auth.state else { return }
            historyStore.recordDeferred(track, for: user) { [weak self] tracks in
                Task { @MainActor [weak self] in
                    guard let self, case let .signedIn(currentUser) = auth.state,
                          (currentUser.urn ?? currentUser.permalinkURL.absoluteString)
                            == (user.urn ?? user.permalinkURL.absoluteString) else { return }
                    history.tracks = tracks
                }
            }
        }
        historyAccountObservation = auth.$state.sink { [weak self] state in
            guard let self else { return }
            if case let .signedIn(user) = state {
                history.tracks = LaunchMetrics.measure("History restore") { self.historyStore.restore(for: user) }
            } else {
                history.tracks = []
            }
        }
        playback.onTrackEnded = { [weak self] in
            self?.selectRelativeTrack(offset: 1, isAutomatic: true)
        }
        playback.onNext = { [weak self] in
            self?.selectRelativeTrack(offset: 1)
        }
        playback.onPrevious = { [weak self] in
            self?.selectRelativeTrack(offset: -1)
        }
        likesObservation = likes.tracksPublisher.dropFirst().sink { [weak self] tracks in
            guard let self, queue.source == .likes else { return }
            queue.replaceLikes(tracks, currentURN: playback.currentTrack?.urn)
            saveQueue()
            prefetchNextTrack(likedTracks: tracks)
        }
        playlistsObservation = playlists.$cache.dropFirst().sink { [weak self] cache in
            guard let self, case let .playlist(urn) = queue.source,
                  let playlist = cache.contents[urn]?.playlist
                    ?? cache.playlists.first(where: { $0.urn == urn }),
                  queue.sourceTitle != playlist.title else { return }
            queue.sourceTitle = playlist.title
            saveQueue()
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        let startup = LaunchMetrics.begin("Startup task")
        defer {
            LaunchMetrics.end(startup)
            LaunchMetrics.markOnce("Startup task finished")
        }
        await auth.restore()
        if case .signedIn = auth.state {
            await likes.restoreCache()
            playback.discardRestoredLikeState()
            playback.scheduleRestoredPrefetch { [auth, client] track in
                let accessToken = try await auth.validAccessToken()
                try Task.checkCancellation()
                return try await LaunchMetrics.measureAsync("Saved track stream resolution") {
                    try await client.resolvePlayback(track: track, accessToken: accessToken)
                }
            }
        }
    }

    func beginSignIn() {
        guard websiteLogin == nil else { return }
        errorMessage = nil
        websiteLogin = WebsiteLogin { [weak self] token in
            guard let self else { return }
            websiteLogin = nil
            Task { await self.signIn(token: token) }
        }
    }

    func cancelSignIn() {
        websiteLogin?.stop()
        websiteLogin = nil
    }

    /// Signs in with an oauth_token cookie value copied from a signed-in browser.
    func importCopiedSession() async {
        guard sessionImportPhase == nil else { return }
        guard let copied = NSPasteboard.general.string(forType: .string) else {
            errorMessage = "Copy the oauth_token cookie value from your SoundCloud browser session first."
            importFailureCount += 1
            return
        }
        let token = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (20...512).contains(token.count),
              token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !token.contains(";") else {
            errorMessage = "Copy only the oauth_token cookie value, then try again."
            importFailureCount += 1
            return
        }
        sessionImportPhase = .importing
        cancelSignIn()
        // Any earlier error stays up through the retry, until an outcome replaces it.
        await auth.signIn(token: token)
        if case .signedIn = auth.state {
            // The token stays copied until it works, so a failed import can be retried.
            if NSPasteboard.general.string(forType: .string) == copied {
                NSPasteboard.general.clearContents()
            }
            errorMessage = nil
            sessionImportPhase = .succeeded
            await finishSignIn()
            // Holds the checkmark on screen before the signed-in view takes over.
            try? await Task.sleep(for: .seconds(0.9))
        } else {
            if case let .failed(message) = auth.state { errorMessage = message }
            importFailureCount += 1
        }
        sessionImportPhase = nil
    }

    private func signIn(token: String) async {
        cancelSignIn()
        errorMessage = nil
        await auth.signIn(token: token)
        await finishSignIn()
    }

    private func finishSignIn() async {
        guard case .signedIn = auth.state else { return }
        await likes.restoreCache()
        playback.discardRestoredLikeState()
    }

    func signOut() async {
        shuffleQueueTask?.cancel()
        trackSelectionTask?.cancel()
        playbackTask?.cancel()
        queuePrefetchTask?.cancel()
        queuePrefetchTask = nil
        prefetchedTrack = nil
        playbackTask = nil
        playbackRequestID = nil
        playback.resetSession()
        queue = TrackQueue(source: .single, tracks: playback.currentTrack.map { [$0] } ?? [])
        saveQueue()
        audioTap.setVisualizerVisible(false)
        followingTask?.cancel()
        followingTask = nil
        followingRequestID = nil
        followingStatuses = [:]
        likes.clear()
        reposts.clear()
        playlists.clear()
        feed.clear()
        // Responses still in flight from this session are not cached.
        trackDetailsCache.reset()
        artistDetailsCache.reset()
        artistWebProfilesCache.reset()
        relatedArtistsCache.reset()
        waveformCache.reset()
        firstCommentPageCache.reset()
        firstArtistCommentPageCache.reset()
        firstRelatedTrackPageCache.reset()
        firstTrackPlaylistPageCache.reset()
        trackPlaylistPreviewCache.reset()
        firstArtistTrackPageCache.reset()
        firstArtistRepostPageCache.reset()
        firstArtistPlaylistRepostPageCache.reset()
        firstArtistPlaylistPageCache.reset()
        firstArtistLikePageCache.reset()
        firstArtistPlaylistLikePageCache.reset()
        firstSearchTrackPageCache.reset()
        firstSearchPlaylistPageCache.reset()
        firstSearchUserPageCache.reset()
        searchCategoryCache.removeAll()
        searchSuggestionCache.reset()
        artistHeaderCache.reset()
        stationCache.reset()
        stationMetadataCache.reset()
        loadingStations.removeAll()
        commentDrafts.removeAll()
        errorMessage = nil
        await auth.signOut()
    }

    func play(_ track: SoundCloudTrack, position: Double = 0) async {
        guard track.access != .protected else { return }
        // Detail and waveform controls retain an existing list when possible.
        if !queue.tracks.contains(where: { $0.urn == track.urn }),
           !(queue.source == .likes && likes.isLiked(track)) {
            shuffleQueueTask?.cancel()
            queue = TrackQueue(source: .single, tracks: [track])
            queue.setShuffle(playback.isShuffleEnabled, currentURN: track.urn)
        }
        trackSelectionTask?.cancel()
        saveQueue()
        await loadPlayback(track, position: position)
    }

    func playLikedTrack(_ track: SoundCloudTrack) async {
        await play(track, queue: TrackQueue(source: .likes, tracks: []))
    }

    func play(_ track: SoundCloudTrack, queue: TrackQueue, loadRemainingTracks: Bool = false) async {
        var queue = queue
        appendAvailableStationTracks(to: &queue)
        queue.replaceLikes(likes.tracks, currentURN: playback.currentTrack?.urn)
        queue.setShuffle(playback.isShuffleEnabled, currentURN: track.urn)
        // A station's seed or a collection's first track may be copy-protected; start after it.
        guard let track = track.access == .protected
            ? queue.relativeTrack(to: track.urn, offset: 1, wraps: false) : track else { return }
        shuffleQueueTask?.cancel()
        trackSelectionTask?.cancel()
        self.queue = queue
        saveQueue()
        if loadRemainingTracks {
            loadRemainingShuffleTracks()
        }
        await loadPlayback(track)
    }

    func continuePlaybackInStation(urn: String, title: String, tracks: [SoundCloudTrack], continuingTrackURN: String) {
        guard let currentTrack = playback.currentTrack,
              currentTrack.urn == continuingTrackURN,
              queue.source != .station(urn), !tracks.isEmpty else { return }
        shuffleQueueTask?.cancel()
        trackSelectionTask?.cancel()
        // Keep the current player item and position. Deduplication leaves the seed first,
        // even when the station omits it or returns it later in the list.
        queue = TrackQueue(source: .station(urn), tracks: [currentTrack] + tracks, sourceTitle: title)
        appendAvailableStationTracks(to: &queue)
        queue.setShuffle(playback.isShuffleEnabled, currentURN: currentTrack.urn)
        saveQueue()
        if !playback.isPlaybackActive {
            playback.togglePlayPause()
        }
        prefetchNextTrack()
    }

    private func loadRemainingShuffleTracks() {
        shuffleQueueTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                while queue.nextPageURL != nil {
                    try Task.checkCancellation()
                    let page = try await nextQueuePage()
                    try Task.checkCancellation()
                    try queue.append(page)
                    if queue.nextPageURL == nil {
                        // Shuffle once all pages are loaded, keeping the playing track first.
                        queue.setShuffle(false, currentURN: nil)
                        queue.setShuffle(playback.isShuffleEnabled, currentURN: playback.currentTrack?.urn)
                    }
                    saveQueue()
                    prefetchNextTrack()
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func addToQueue(_ track: SoundCloudTrack) {
        queue.replaceLikes(likes.tracks, currentURN: playback.currentTrack?.urn)
        queue.setShuffle(playback.isShuffleEnabled, currentURN: playback.currentTrack?.urn)
        guard queue.add(track, after: playback.currentTrack?.urn) else { return }
        shuffleQueueTask?.cancel()
        trackSelectionTask?.cancel()
        saveQueue()
        prefetchNextTrack()
    }

    func removeFromQueue(_ track: SoundCloudTrack) {
        queue.replaceLikes(likes.tracks, currentURN: playback.currentTrack?.urn)
        guard queue.remove(track, currentURN: playback.currentTrack?.urn) else { return }
        shuffleQueueTask?.cancel()
        trackSelectionTask?.cancel()
        if queue.tracks.isEmpty {
            // Replace the queue too, so remaining pages or new likes cannot refill it.
            playback.resetSession(preservingPlayback: false)
            queue = TrackQueue(source: .single, tracks: [])
            queue.setShuffle(playback.isShuffleEnabled, currentURN: nil)
        }
        saveQueue()
        prefetchNextTrack()
    }

    func clearQueue() {
        shuffleQueueTask?.cancel()
        trackSelectionTask?.cancel()
        let current = playback.currentTrack
        queue = TrackQueue(source: .single, tracks: current.map { [$0] } ?? [])
        queue.setShuffle(playback.isShuffleEnabled, currentURN: current?.urn)
        saveQueue()
        prefetchNextTrack()
    }

    func moveQueueTracks(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        queue.replaceLikes(likes.tracks, currentURN: playback.currentTrack?.urn)
        guard queue.move(fromOffsets: offsets, toOffset: destination) else { return }
        shuffleQueueTask?.cancel()
        trackSelectionTask?.cancel()
        saveQueue()
        prefetchNextTrack()
    }

    private func saveQueue() {
        queueStore.save(queue)
    }

    var queuePlaylist: (urn: String, title: String)? {
        guard case let .playlist(urn) = queue.source else { return nil }
        // The playlistsObservation sink updates the queue when this playlist title changes.
        // Reading the cache here does not subscribe views to every playlist load.
        guard let title = playlists.cache.contents[urn]?.playlist.title
            ?? playlists.playlists.first(where: { $0.urn == urn })?.title
            ?? queue.sourceTitle else { return nil }
        return (urn, title)
    }

    private func loadPlayback(
        _ track: SoundCloudTrack,
        position: Double = 0,
        autoplay: Bool = true,
        direction: PlaybackController.TrackChangeDirection = .forward
    ) async {
        guard !Task.isCancelled else { return }
        playbackTask?.cancel()
        // Publish the selection before any network wait so the artwork,
        // waveform, and repeated Next presses use the new track immediately.
        let requestID = playback.beginLoading(
            track: track,
            position: position,
            autoplay: autoplay,
            direction: direction
        )
        await resolvePlayback(track, requestID: requestID)
    }

    private func resolvePlayback(_ track: SoundCloudTrack, requestID: UUID) async {
        playbackRequestID = requestID
        errorMessage = nil

        let task = Task { @MainActor in
            defer {
                // An older request must not clear the latest request's task.
                if playbackRequestID == requestID {
                    // No-op once the source was attached or an error was set.
                    playback.failLoading(requestID: requestID)
                    playbackTask = nil
                    playbackRequestID = nil
                }
            }
            do {
                try Task.checkCancellation()
                if await playback.loadPrefetched(requestID: requestID) {
                    // Resolve the next track only after the current one, so it
                    // never competes with the stream the listener is waiting on.
                    if !Task.isCancelled, playbackRequestID == requestID {
                        prefetchNextTrack()
                    }
                    return
                }
                try Task.checkCancellation()
                let accessToken = try await auth.validAccessToken()
                try Task.checkCancellation()
                let source = try await LaunchMetrics.measureAsync("Current track stream resolution") {
                    try await client.resolvePlayback(track: track, accessToken: accessToken)
                }
                guard !Task.isCancelled,
                      playbackRequestID == requestID else { return }
                LaunchMetrics.measure("Player item attachment") {
                    playback.load(source: source, requestID: requestID)
                }
                prefetchNextTrack()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      playbackRequestID == requestID else { return }
                playback.failLoading(requestID: requestID, message: error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
        playbackTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func trackDetails(for track: SoundCloudTrack) async throws
        -> SoundCloudTrackDetails {
        try await trackDetailsCache.value(for: TrackCacheKey(track: track)) { [auth, client] in
            let accessToken = try await auth.validAccessToken()
            return try await client.track(
                urn: track.urn,
                secretToken: track.secretToken,
                accessToken: accessToken
            )
        }
    }

    func addTrackComment(
        for track: SoundCloudTrack, body: String, timestampMilliseconds: Int? = nil
    ) async throws
        -> SoundCloudComment {
        let accessToken = try await auth.validAccessToken()
        let comment = try await client.addTrackComment(
            urn: track.urn, body: body,
            timestampMilliseconds: timestampMilliseconds, accessToken: accessToken
        )
        let cacheKey = TrackCacheKey(track: track)
        firstCommentPageCache.remove(cacheKey)
        firstArtistCommentPageCache.removeAll()
        if var details = trackDetailsCache.cached(cacheKey), let count = details.commentCount {
            details.commentCount = count + 1
            trackDetailsCache.insert(details, forKey: cacheKey)
        }
        return comment
    }

    func deleteTrackComment(_ comment: SoundCloudComment, on track: SoundCloudTrack) async throws {
        let accessToken = try await auth.validAccessToken()
        try await client.deleteTrackComment(urn: comment.urn, accessToken: accessToken)
        let cacheKey = TrackCacheKey(track: track)
        firstCommentPageCache.remove(cacheKey)
        firstArtistCommentPageCache.removeAll()
        if var details = trackDetailsCache.cached(cacheKey), let count = details.commentCount {
            details.commentCount = max(0, count - 1)
            trackDetailsCache.insert(details, forKey: cacheKey)
        }
    }

    func commentLikes(for track: SoundCloudTrack, comments: [SoundCloudComment]) async throws
        -> [String: SoundCloudCommentLikes] {
        let accessToken = try await auth.validAccessToken()
        return try await client.commentLikes(
            trackURN: track.urn, commentURNs: comments.map(\.urn), accessToken: accessToken
        )
    }

    func setCommentLiked(_ isLiked: Bool, comment: SoundCloudComment, on track: SoundCloudTrack)
        async throws {
        let accessToken = try await auth.validAccessToken()
        try await client.setCommentLiked(
            trackURN: track.urn, commentURN: comment.urn, isLiked: isLiked, accessToken: accessToken
        )
    }

    func trackComments(for track: SoundCloudTrack, pageURL: URL? = nil) async throws
        -> SoundCloudCommentPage {
        if let pageURL {
            let accessToken = try await auth.validAccessToken()
            return try await client.trackComments(
                urn: track.urn, secretToken: track.secretToken,
                accessToken: accessToken, pageURL: pageURL
            )
        }

        // The detail list and the waveform markers share this request.
        return try await firstCommentPageCache.value(for: TrackCacheKey(track: track)) { [auth, client] in
            let accessToken = try await auth.validAccessToken()
            return try await client.trackComments(
                urn: track.urn, secretToken: track.secretToken, accessToken: accessToken
            )
        }
    }

    func cachedTrackDetails(for track: SoundCloudTrack)
        -> SoundCloudTrackDetails? {
        trackDetailsCache.cached(TrackCacheKey(track: track))
    }

    func cachedArtistDetails(for artist: SoundCloudUser) -> SoundCloudArtistDetails? {
        artistDetailsCache.cached(artist.permalinkURL as NSURL)
    }

    func artistDetails(for artist: SoundCloudUser) async throws -> SoundCloudArtistDetails {
        try await artistDetailsCache.value(for: artist.permalinkURL as NSURL) { [auth, client] in
            let accessToken = try await auth.validAccessToken()
            return try await client.artist(artist, accessToken: accessToken)
        }
    }

    func cachedArtistWebProfiles(for artist: SoundCloudUser) -> [SoundCloudWebProfile]? {
        artistWebProfilesCache.cached(artist.permalinkURL as NSURL)
    }

    func artistWebProfiles(for artist: SoundCloudUser) async throws -> [SoundCloudWebProfile] {
        if let cached = cachedArtistWebProfiles(for: artist) { return cached }
        guard let urn = artist.urn else { throw SoundCloudError.invalidData }
        return try await artistWebProfilesCache.value(for: artist.permalinkURL as NSURL) { [auth, client] in
            let accessToken = try await auth.validAccessToken()
            return try await client.artistWebProfiles(urn: urn, accessToken: accessToken)
        }
    }

    func cachedRelatedArtists(for artist: SoundCloudUser) -> [SoundCloudUser]? {
        relatedArtistsCache.cached(artist.permalinkURL as NSURL)
    }

    func relatedArtists(for artist: SoundCloudUser) async throws -> [SoundCloudUser] {
        guard let urn = artist.urn else { throw SoundCloudError.invalidData }
        return try await relatedArtistsCache.value(for: artist.permalinkURL as NSURL) { [auth, client] in
            let accessToken = try await auth.validAccessToken()
            return try await client.relatedArtists(urn: urn, accessToken: accessToken)
        }
    }

    func cachedIsFollowingArtist(_ artist: SoundCloudUser) -> Bool? {
        guard let urn = artist.urn else { return nil }
        return followingStatuses[urn]
    }

    func isFollowingArtist(_ artist: SoundCloudUser) async throws -> Bool {
        guard let urn = artist.urn else { throw SoundCloudError.invalidData }
        if let followed = cachedIsFollowingArtist(artist) { return followed }
        if followingTask == nil {
            followingRequestID = UUID()
            followingTask = Task {
                let accessToken = try await auth.validAccessToken()
                return try await client.followedArtistURNs(accessToken: accessToken)
            }
        }
        let requestID = followingRequestID
        do {
            let followed = try await followingTask!.value
            try Task.checkCancellation()
            guard followingRequestID == requestID else { throw CancellationError() }
            let isFollowed = followingStatuses[urn] ?? followed.contains(urn)
            followingStatuses[urn] = isFollowed
            return isFollowed
        } catch {
            if followingRequestID == requestID, !Task.isCancelled {
                followingTask = nil
                followingRequestID = nil
            }
            throw error
        }
    }

    func setArtistFollowed(_ artist: SoundCloudUser, isFollowed: Bool) async throws {
        guard let urn = artist.urn else { throw SoundCloudError.invalidData }
        let accessToken = try await auth.validAccessToken()
        let requestID = followingRequestID
        try await client.setArtistFollowed(urn: urn, isFollowed: isFollowed, accessToken: accessToken)
        guard requestID == followingRequestID else { throw CancellationError() }
        followingStatuses[urn] = isFollowed
        // Refresh follower counts the next time an artist page opens. A request
        // already in flight may predate the change, so it is not cached either.
        artistDetailsCache.removeAll()
    }

    func cachedArtistHeader(for artist: SoundCloudUser) -> CachedArtistHeader? {
        artistHeaderCache.cached(artist.permalinkURL as NSURL) ?? nil
    }

    /// Whether a previous lookup found that the artist has no profile header.
    func isArtistHeaderKnownMissing(_ artist: SoundCloudUser) -> Bool {
        guard case .some(nil) = artistHeaderCache.cached(artist.permalinkURL as NSURL) else {
            return false
        }
        return true
    }

    func artistHeader(for artist: SoundCloudUser) async throws -> CachedArtistHeader? {
        try await artistHeaderCache.value(for: artist.permalinkURL as NSURL) { [client, artworkLoader] in
            guard let url = try await client.artistHeaderURL(for: artist) else { return nil }
            let data = try await artworkLoader.data(for: url)
            guard let image = NSImage(data: data) else { throw SoundCloudError.invalidData }
            return CachedArtistHeader(artistURL: artist.permalinkURL, artworkURL: url, image: image)
        }
    }

    func artistUsers(
        for artist: SoundCloudUser,
        list: ArtistUserList,
        pageURL: URL? = nil
    ) async throws -> SoundCloudUserPage {
        guard let urn = artist.urn else { throw SoundCloudError.invalidData }
        let accessToken = try await auth.validAccessToken()
        return try await client.artistUsers(
            urn: urn, list: list, accessToken: accessToken, pageURL: pageURL
        )
    }

    func cachedFirstArtistCommentPage(for artist: SoundCloudUser) -> SoundCloudCommentPage? {
        firstArtistCommentPageCache.cached(artist.permalinkURL as NSURL)
    }

    func artistComments(for artist: SoundCloudUser, pageURL: URL? = nil) async throws
        -> SoundCloudCommentPage {
        guard let urn = artist.urn else { throw SoundCloudError.invalidData }
        if let pageURL {
            let accessToken = try await auth.validAccessToken()
            return try await client.artistComments(urn: urn, accessToken: accessToken, pageURL: pageURL)
        }

        // The artist page's preview and the full list share this request.
        return try await firstArtistCommentPageCache.value(for: artist.permalinkURL as NSURL) { [auth, client] in
            let accessToken = try await auth.validAccessToken()
            return try await client.artistComments(urn: urn, accessToken: accessToken)
        }
    }

    func searchCategory(for query: String) -> SearchCategory {
        searchCategoryCache.value(forKey: query as NSString) ?? .tracks
    }

    func rememberSearchCategory(_ category: SearchCategory, for query: String) {
        searchCategoryCache.insert(category, forKey: query as NSString)
    }

    /// Autocomplete for the search field. A part that fails to load is left out rather than raising an error.
    func searchSuggestions(for query: String) async -> SoundCloudSearchSuggestions {
        let suggestions = try? await searchSuggestionCache.value(for: query.lowercased() as NSString) { [auth, client] in
            let accessToken = try await auth.validAccessToken()
            async let queries = client.searchQueries(query: query, accessToken: accessToken)
            async let results = client.searchTopResults(query: query, accessToken: accessToken)
            let loadedQueries = try? await queries
            let loadedResults = try? await results
            // Cache nothing when both fail, so that typing on asks again.
            guard loadedQueries != nil || loadedResults != nil else { throw SoundCloudError.network }
            return SoundCloudSearchSuggestions(queries: loadedQueries ?? [], results: loadedResults ?? [])
        }
        return suggestions ?? SoundCloudSearchSuggestions()
    }

    func cachedFirstSearchTrackPage(query: String? = nil, genres: String? = nil, tags: String? = nil)
        -> SoundCloudTrackPage? {
        firstSearchTrackPageCache.cached(SearchTrackCacheKey(query: query, genres: genres, tags: tags))
    }

    func cachedFirstSearchPlaylistPage(query: String) -> SoundCloudPlaylistPage? {
        firstSearchPlaylistPageCache.cached(query as NSString)
    }

    func cachedFirstSearchUserPage(query: String) -> SoundCloudUserPage? {
        firstSearchUserPageCache.cached(query as NSString)
    }

    func searchTracks(query: String? = nil, genres: String? = nil, tags: String? = nil, pageURL: URL? = nil) async throws -> SoundCloudTrackPage {
        if let pageURL {
            let accessToken = try await auth.validAccessToken()
            return try await client.searchTracks(query: query, genres: genres, tags: tags, accessToken: accessToken, pageURL: pageURL)
        }
        let cacheKey = SearchTrackCacheKey(query: query, genres: genres, tags: tags)
        return try await firstSearchTrackPageCache.value(for: cacheKey) { [auth, client] in
            let accessToken = try await auth.validAccessToken()
            return try await client.searchTracks(query: query, genres: genres, tags: tags, accessToken: accessToken, pageURL: nil)
        }
    }

    func searchPlaylists(query: String, pageURL: URL? = nil) async throws -> SoundCloudPlaylistPage {
        if let pageURL {
            let accessToken = try await auth.validAccessToken()
            return try await client.searchPlaylists(query: query, accessToken: accessToken, pageURL: pageURL)
        }
        return try await firstSearchPlaylistPageCache.value(for: query as NSString) { [auth, client] in
            let accessToken = try await auth.validAccessToken()
            return try await client.searchPlaylists(query: query, accessToken: accessToken, pageURL: nil)
        }
    }

    func searchUsers(query: String, pageURL: URL? = nil) async throws -> SoundCloudUserPage {
        if let pageURL {
            let accessToken = try await auth.validAccessToken()
            return try await client.searchUsers(query: query, accessToken: accessToken, pageURL: pageURL)
        }
        return try await firstSearchUserPageCache.value(for: query as NSString) { [auth, client] in
            let accessToken = try await auth.validAccessToken()
            return try await client.searchUsers(query: query, accessToken: accessToken, pageURL: nil)
        }
    }

    /// The first page of each content tab that is already cached, so the page can show them at once.
    func cachedFirstArtistPages(for artist: SoundCloudUser) -> ArtistFirstPages {
        guard let urn = artist.urn as NSString? else { return ArtistFirstPages() }
        return ArtistFirstPages(
            tracks: firstArtistTrackPageCache.cached(urn),
            reposts: firstArtistRepostPageCache.cached(urn),
            repostedPlaylists: firstArtistPlaylistRepostPageCache.cached(urn),
            playlists: firstArtistPlaylistPageCache.cached(urn),
            likes: firstArtistLikePageCache.cached(urn),
            likedPlaylists: firstArtistPlaylistLikePageCache.cached(urn)
        )
    }

    func artistTracks(for artist: SoundCloudUser, pageURL: URL? = nil) async throws
        -> SoundCloudTrackPage {
        try await artistPage(artist, pageURL: pageURL, firstPages: firstArtistTrackPageCache) { [client] urn, accessToken, pageURL in
            var page = try await client.artistTracks(urn: urn, accessToken: accessToken, pageURL: pageURL)
            guard pageURL == nil else { return page }
            // Some artists' tracks start after several empty pages. Skip them here so the
            // cached first page holds tracks, rather than the page refetching them each visit.
            var seen: Set<URL> = []
            while page.tracks.isEmpty, let nextURL = page.nextURL {
                guard seen.insert(nextURL).inserted else { throw SoundCloudError.invalidData }
                page = try await client.artistTracks(urn: urn, accessToken: accessToken, pageURL: nextURL)
            }
            return page
        }
    }

    func artistReposts(for artist: SoundCloudUser, pageURL: URL? = nil) async throws
        -> SoundCloudTrackPage {
        try await artistPage(artist, pageURL: pageURL, firstPages: firstArtistRepostPageCache) { [client] in
            try await client.artistReposts(urn: $0, accessToken: $1, pageURL: $2)
        }
    }

    func artistPlaylistReposts(for artist: SoundCloudUser, pageURL: URL? = nil) async throws
        -> SoundCloudPlaylistPage {
        try await artistPage(artist, pageURL: pageURL, firstPages: firstArtistPlaylistRepostPageCache) { [client] in
            try await client.artistPlaylistReposts(urn: $0, accessToken: $1, pageURL: $2)
        }
    }

    func artistPlaylistLikes(for artist: SoundCloudUser, pageURL: URL? = nil) async throws
        -> SoundCloudPlaylistPage {
        try await artistPage(artist, pageURL: pageURL, firstPages: firstArtistPlaylistLikePageCache) { [client] in
            try await client.artistPlaylistLikes(urn: $0, accessToken: $1, pageURL: $2)
        }
    }

    func artistLikes(for artist: SoundCloudUser, pageURL: URL? = nil) async throws
        -> SoundCloudTrackPage {
        try await artistPage(artist, pageURL: pageURL, firstPages: firstArtistLikePageCache) { [client] in
            try await client.artistLikes(urn: $0, accessToken: $1, pageURL: $2)
        }
    }

    func artistPlaylists(for artist: SoundCloudUser, pageURL: URL? = nil) async throws
        -> SoundCloudPlaylistPage {
        try await artistPage(artist, pageURL: pageURL, firstPages: firstArtistPlaylistPageCache) { [client] in
            try await client.artistPlaylists(urn: $0, accessToken: $1, pageURL: $2)
        }
    }

    // Later pages are not cached: the page that requested them keeps them.
    private func artistPage<Page>(
        _ artist: SoundCloudUser,
        pageURL: URL?,
        firstPages: RequestCache<NSString, Page>,
        fetch: @escaping @MainActor (_ urn: String, _ accessToken: String, _ pageURL: URL?) async throws -> Page
    ) async throws -> Page {
        guard let urn = artist.urn else { throw SoundCloudError.invalidData }
        if let pageURL {
            return try await fetch(urn, try await auth.validAccessToken(), pageURL)
        }
        return try await firstPages.value(for: urn as NSString) { [auth] in
            try await fetch(urn, try await auth.validAccessToken(), nil)
        }
    }

    enum StationSource {
        case track(SoundCloudTrack)
        case artist(SoundCloudUser)
    }

    func stationSource(urn: String) async throws -> StationSource {
        let components = urn.split(separator: ":")
        guard components.count >= 2, let id = components.last else {
            throw SoundCloudError.invalidData
        }
        let accessToken = try await auth.validAccessToken()
        switch components[components.count - 2] {
        case "track-stations":
            let details = try await client.track(
                urn: "soundcloud:tracks:\(id)", secretToken: nil, accessToken: accessToken
            )
            trackDetailsCache.insert(details, forKey: TrackCacheKey(track: details.track))
            return .track(details.track)
        case "artist-stations":
            let details = try await client.artist(urn: "soundcloud:users:\(id)", accessToken: accessToken)
            artistDetailsCache.insert(details, forKey: details.user.permalinkURL as NSURL)
            return .artist(details.user)
        default:
            throw SoundCloudError.invalidData
        }
    }

    func cachedStation(urn: String) -> SoundCloudStation? {
        stationCache.cached(urn as NSString)
    }

    private func stationMetadata(urn: String) async throws -> RawSystemPlaylist {
        try await stationMetadataCache.value(for: urn as NSString) { [auth, client] in
            let token = try await auth.validAccessToken()
            return try await client.stationMetadata(urn: urn, accessToken: token)
        }
    }

    func station(urn: String) async throws -> SoundCloudStation {
        // Hover prefetch and navigation share this request.
        try await stationCache.value(for: urn as NSString) { [weak self, auth, client] in
            guard let self else { throw CancellationError() }
            // The finished station is cached as this returns, with no gap between them.
            defer {
                // Sign-out cancels the request and has already cleared loading stations.
                if !Task.isCancelled { loadingStations[urn] = nil }
            }
            let metadata = try await stationMetadata(urn: urn)
            let accessToken = try await auth.validAccessToken()
            return try await client.hydrateStation(metadata, accessToken: accessToken) { [weak self] station in
                await self?.updateLoadingStation(station, urn: urn)
            }
        }
    }

    private func appendAvailableStationTracks(to queue: inout TrackQueue) {
        guard case let .station(urn) = queue.source,
              let station = cachedStation(urn: urn) ?? loadingStations[urn] else { return }
        // Loading may finish between rendering Start and running its playback task.
        try? queue.append(SoundCloudTrackPage(tracks: station.tracks, nextURL: nil))
    }

    // Runs in the station request, so its cancellation is visible here.
    private func updateLoadingStation(_ station: SoundCloudStation, urn: String) {
        // Progress from a request cancelled by sign-out must not reach the new session.
        guard !Task.isCancelled else { return }
        loadingStations[urn] = station
        guard queue.source == .station(urn) else { return }
        // Append deduplicates tracks and respects tracks removed by the user.
        try? queue.append(SoundCloudTrackPage(tracks: station.tracks, nextURL: nil))
        saveQueue()
        prefetchNextTrack()
    }

    func playlistDetails(urn: String, title: String) async -> SoundCloudPlaylist? {
        await playlists.restoreContents(urn: urn)
        if let cached = playlists.cache.contents[urn]?.playlist
            ?? playlists.playlists.first(where: { $0.urn == urn }) { return cached }
        if urn.hasPrefix("soundcloud:system-playlists:") {
            return .systemPlaylist(urn: urn, title: title)
        }
        do {
            let accessToken = try await auth.validAccessToken()
            return try await client.playlist(urn: urn, accessToken: accessToken)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func playlistTracks(for playlist: SoundCloudPlaylist, pageURL: URL? = nil) async throws
        -> SoundCloudTrackPage {
        let accessToken = try await auth.validAccessToken()
        return try await client.playlistTracks(
            urn: playlist.urn,
            accessToken: accessToken,
            pageURL: pageURL
        )
    }

    func cachedRelatedTracks(for track: SoundCloudTrack) -> SoundCloudTrackPage? {
        firstRelatedTrackPageCache.cached(track.urn as NSString)
    }

    func cachedPlaylistsContaining(_ track: SoundCloudTrack) -> SoundCloudPlaylistPage? {
        firstTrackPlaylistPageCache.cached(track.urn as NSString)
    }

    func cachedPlaylistPreview(containing track: SoundCloudTrack) -> SoundCloudPlaylistPage? {
        trackPlaylistPreviewCache.cached(track.urn as NSString)
    }

    /// The first few playlists that include the track, for the track's page.
    func playlistPreview(containing track: SoundCloudTrack, limit: Int) async throws
        -> SoundCloudPlaylistPage {
        try await trackPlaylistPreviewCache.value(for: track.urn as NSString) { [auth, client] in
            let accessToken = try await auth.validAccessToken()
            return try await client.playlistsContainingTrack(
                urn: track.urn, accessToken: accessToken, limit: limit
            )
        }
    }

    func relatedTracks(for track: SoundCloudTrack, pageURL: URL? = nil) async throws
        -> SoundCloudTrackPage {
        if let pageURL {
            let accessToken = try await auth.validAccessToken()
            return try await client.relatedTracks(urn: track.urn, accessToken: accessToken, pageURL: pageURL)
        }
        return try await firstRelatedTrackPageCache.value(for: track.urn as NSString) { [auth, client] in
            let accessToken = try await auth.validAccessToken()
            return try await client.relatedTracks(urn: track.urn, accessToken: accessToken, pageURL: nil)
        }
    }

    func playlistsContaining(_ track: SoundCloudTrack, pageURL: URL? = nil) async throws
        -> SoundCloudPlaylistPage {
        if let pageURL {
            let accessToken = try await auth.validAccessToken()
            return try await client.playlistsContainingTrack(
                urn: track.urn, accessToken: accessToken, pageURL: pageURL
            )
        }
        return try await firstTrackPlaylistPageCache.value(for: track.urn as NSString) { [auth, client] in
            let accessToken = try await auth.validAccessToken()
            return try await client.playlistsContainingTrack(
                urn: track.urn, accessToken: accessToken, pageURL: nil
            )
        }
    }

    func waveform(for track: SoundCloudTrack) async throws
        -> SoundCloudWaveform {
        var waveformURL = track.waveformURL
        if waveformURL == nil {
            let details = try await trackDetails(for: track)
            try Task.checkCancellation()
            waveformURL = details.track.waveformURL
        }
        guard let waveformURL else {
            throw SoundCloudError.invalidData
        }
        // A cancelled prefetch may still serve a visible waveform.
        return try await waveformCache.value(for: waveformURL as NSURL) { [client] in
            try await client.waveform(from: waveformURL)
        }
    }

    func cachedWaveform(for track: SoundCloudTrack) -> SoundCloudWaveform? {
        guard let waveformURL = track.waveformURL
            ?? cachedTrackDetails(for: track)?.track.waveformURL else { return nil }
        return waveformCache.cached(waveformURL as NSURL)
    }

    func clearError() {
        errorMessage = nil
    }

    func toggleCurrentTrackLike() {
        guard let track = playback.currentTrack else { return }
        if !likes.isLiked(track) { currentTrackLikeEvents += 1 }
        Task {
            do {
                try await likes.toggleLike(track)
            } catch {
                likeErrorMessage = error.localizedDescription
            }
        }
    }

    func toggleShuffle() {
        shuffleQueueTask?.cancel()
        trackSelectionTask?.cancel()
        playback.toggleShuffle()
        queue.replaceLikes(likes.tracks, currentURN: playback.currentTrack?.urn)
        queue.setShuffle(playback.isShuffleEnabled, currentURN: playback.currentTrack?.urn)
        saveQueue()
        prefetchNextTrack()
    }

    private func prefetchNextTrack(likedTracks: [SoundCloudTrack]? = nil) {
        // Keep the saved track's standby player until the user chooses playback.
        guard playback.sessionToRestore == nil else { return }
        var resolvedQueue = queue
        resolvedQueue.replaceLikes(likedTracks ?? likes.tracks, currentURN: playback.currentTrack?.urn)
        let currentURN = playback.currentTrack?.urn
        // A sequential page boundary has no known next track yet.
        let needsPage = !playback.isShuffleEnabled && resolvedQueue.needsNextPage(after: currentURN)
        let candidate = currentURN == nil || needsPage ? nil
            : resolvedQueue.relativeTrack(to: currentURN, offset: 1)
        let next = candidate?.urn == currentURN ? nil : candidate
        playback.prefetch(playback.isPlaybackActive ? next : nil) { [auth, client] in
            guard let next else { throw CancellationError() }
            let accessToken = try await auth.validAccessToken()
            try Task.checkCancellation()
            return try await LaunchMetrics.measureAsync("Next track stream resolution") {
                try await client.resolvePlayback(track: next, accessToken: accessToken)
            }
        }
        guard next != prefetchedTrack else { return }
        queuePrefetchTask?.cancel()
        prefetchedTrack = next
        guard let next else {
            queuePrefetchTask = nil
            return
        }
        queuePrefetchTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            // Warm the same bounded caches used by the footer and waveform.
            // ArtworkLoader shares in-flight requests with visible artwork.
            async let waveform = try? self.waveform(for: next)
            async let artwork = self.prefetchArtwork(for: next)
            _ = await (waveform, artwork)
        }
    }

    /// Prepare a viewed track's stream after a short dwell, so Play can start without
    /// resolving it. The standby player is released when the caller's task is cancelled.
    func prefetchPlaybackWhileViewing(_ track: SoundCloudTrack) async {
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        // The current track already has a player, or the restore prefetch covers it.
        guard playback.currentTrack?.urn != track.urn else { return }
        playback.prefetch(track, slot: .viewed) { [auth, client] in
            let accessToken = try await auth.validAccessToken()
            try Task.checkCancellation()
            return try await LaunchMetrics.measureAsync("Viewed track stream resolution") {
                try await client.resolvePlayback(track: track, accessToken: accessToken)
            }
        }
        // Wait for the page to leave. A stale signed stream URL must not be reused later.
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3_600))
        }
        playback.discardPrefetch(of: track, in: .viewed)
    }

    private func prefetchArtwork(for track: SoundCloudTrack) async {
        guard let url = track.displayArtworkURL else { return }
        // The footer and the detail page use different renditions.
        async let footer = try? artworkLoader.image(for: url, rendition: .square300)
        async let detail: Void = prefetchDetailArtwork(for: track)
        _ = await (footer, detail)
    }

    func prefetchDetailArtwork(for track: SoundCloudTrack) async {
        guard let url = track.displayArtworkURL else { return }
        async let detail = try? artworkLoader.image(for: url, rendition: .square500)
        // Prepare the source rendition too: the backdrop uses it rather
        // than square500. Cache the extracted accent, not just its JPEG data.
        async let backdrop = try? artworkLoader.image(for: url)
        async let accent = try? artworkLoader.accentColor(for: url)
        _ = await (detail, backdrop, accent)
    }

    func navigateTrack(from track: SoundCloudTrack, offset: Int, queue: TrackQueue) {
        guard !queue.tracks.isEmpty else { return }
        shuffleQueueTask?.cancel()
        var queue = queue
        queue.setShuffle(playback.isShuffleEnabled, currentURN: track.urn)
        selectRelativeTrack(offset: offset, anchorURN: track.urn, navigationQueue: queue)
    }

    private func selectRelativeTrack(
        offset: Int,
        isAutomatic: Bool = false,
        anchorURN: String? = nil,
        navigationQueue: TrackQueue? = nil
    ) {
        trackSelectionTask?.cancel()
        trackSelectionTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            let currentURN = anchorURN ?? playback.currentTrack?.urn
            // A new collection must not display the old queue's playing track
            // while selection waits for this task or another page of tracks.
            var queue = navigationQueue ?? self.queue
            do {
                // Likes use the disk-backed library, including pages added during playback.
                queue.replaceLikes(likes.tracks, currentURN: currentURN)
                if !playback.isShuffleEnabled, offset > 0 {
                    while queue.needsNextPage(after: currentURN) {
                        let page = try await nextQueuePage(in: queue)
                        try Task.checkCancellation()
                        if navigationQueue == nil { queue = self.queue }
                        try queue.append(page)
                        if navigationQueue == nil {
                            self.queue = queue
                            saveQueue()
                        }
                    }
                }
                try Task.checkCancellation()
                guard let track = queue.relativeTrack(
                    to: currentURN,
                    offset: offset,
                    wraps: !isAutomatic || playback.repeatMode == .all
                ) else {
                    if isAutomatic {
                        playback.pause()
                        playback.seek(to: 0)
                    }
                    return
                }
                self.queue = queue
                saveQueue()
                // Queue edits cancel page selection, not the selected stream load.
                trackSelectionTask = nil
                if playback.restartIfLoaded(track) { return }
                await loadPlayback(track, direction: offset < 0 ? .backward : .forward)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func nextQueuePage(in requestedQueue: TrackQueue? = nil) async throws -> SoundCloudTrackPage {
        let source = (requestedQueue ?? queue).source
        let pageURL = (requestedQueue ?? queue).nextPageURL
        let accessToken = try await auth.validAccessToken()
        try Task.checkCancellation()
        switch source {
        case let .tag(tag):
            return try await client.searchTracks(tags: tag, accessToken: accessToken, pageURL: pageURL)
        case let .genre(genre):
            return try await client.searchTracks(genres: genre, accessToken: accessToken, pageURL: pageURL)
        case let .search(query):
            return try await client.searchTracks(query: query, accessToken: accessToken, pageURL: pageURL)
        case .feed:
            let page = try await client.feed(accessToken: accessToken, pageURL: pageURL)
            return SoundCloudTrackPage(tracks: page.items.compactMap(\.content.track), nextURL: page.nextURL)
        case let .artist(urn):
            return try await client.artistTracks(urn: urn, accessToken: accessToken, pageURL: pageURL)
        case let .artistReposts(urn):
            return try await client.artistReposts(urn: urn, accessToken: accessToken, pageURL: pageURL)
        case let .artistLikes(urn):
            return try await client.artistLikes(urn: urn, accessToken: accessToken, pageURL: pageURL)
        case let .playlist(urn):
            return try await client.playlistTracks(urn: urn, accessToken: accessToken, pageURL: pageURL)
        case let .related(urn):
            return try await client.relatedTracks(urn: urn, accessToken: accessToken, pageURL: pageURL)
        case .history, .likes, .single, .station:
            return SoundCloudTrackPage(tracks: [], nextURL: nil)
        }
    }
}

private final class TrackCacheKey: NSObject {
    let urn: String
    let secretToken: String?

    init(track: SoundCloudTrack) {
        urn = track.urn
        secretToken = track.secretToken
    }

    #if DEBUG
    override var description: String { secretToken == nil ? urn : "\(urn) (secret)" }
    #endif

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(urn)
        hasher.combine(secretToken)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TrackCacheKey else { return false }
        return urn == other.urn && secretToken == other.secretToken
    }
}

private final class SearchTrackCacheKey: NSObject {
    let query: String?
    let genres: String?
    let tags: String?

    init(query: String?, genres: String?, tags: String?) {
        self.query = query
        self.genres = genres
        self.tags = tags
    }

    #if DEBUG
    override var description: String {
        [query, genres.map { "genres: \($0)" }, tags.map { "tags: \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }
    #endif

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(query)
        hasher.combine(genres)
        hasher.combine(tags)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SearchTrackCacheKey else { return false }
        return query == other.query && genres == other.genres && tags == other.tags
    }
}
