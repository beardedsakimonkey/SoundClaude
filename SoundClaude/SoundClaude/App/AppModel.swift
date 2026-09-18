import AppKit
import Combine

struct CachedArtistHeader {
    let artistURL: URL
    let artworkURL: URL
    let image: NSImage
}

@MainActor
final class AppModel: ObservableObject {
    let analyzer: SpectrumAnalyzer
    let audioTap: AudioTapController
    let playback: PlaybackController
    let auth: AuthController
    let reposts: RepostsController
    let likes: LikesController
    let playlists: PlaylistsController
    let feed: FeedController
    let artworkLoader: ArtworkLoader

    @Published private(set) var errorMessage: String?
    @Published var likeErrorMessage: String?

    private let client: SoundCloudClient
    private let configurationError: Error?
    private var playbackTask: Task<Void, Never>?
    private var playbackRequestID: UUID?
    private var trackSelectionTask: Task<Void, Never>?
    private var queuePrefetchTask: Task<Void, Never>?
    private var shuffleQueueTask: Task<Void, Never>?
    private var prefetchedTrack: SoundCloudTrack?
    private var likesObservation: AnyCancellable?
    private var followingTask: Task<Set<String>, Error>?
    private var followingRequestID: UUID?
    private var followingOverrides: [String: Bool] = [:]
    private var hasStarted = false
    @Published private(set) var queue = TrackQueue(source: .single, tracks: [])
    private let queueSettingsKey = "playback.queue"
    // These limits bound cache growth as liked-track pages load.
    private let trackDetailsCache = MemoryCache<
        TrackCacheKey,
        SoundCloudTrackDetails
    >(countLimit: 100)
    private let waveformCache = MemoryCache<
        NSURL,
        SoundCloudWaveform
    >(countLimit: 50, totalCostLimit: 8 * 1_024 * 1_024)
    private var waveformRequests: [URL: (id: UUID, task: Task<SoundCloudWaveform, Error>)] = [:]
    private let artistDetailsCache = MemoryCache<NSURL, SoundCloudArtistDetails>(countLimit: 100)
    private var latestArtistHeader: CachedArtistHeader?

    init() {
        let configuration: SoundCloudConfiguration
        do {
            configuration = try .bundled()
            configurationError = nil
        } catch {
            configuration = SoundCloudConfiguration(
                clientID: "",
                clientSecret: ""
            )
            configurationError = error
        }

        guard let analyzer = SpectrumAnalyzer() else {
            fatalError("The fixed audio buffers could not be created.")
        }
        let client = SoundCloudClient(configuration: configuration)
        let audioTap = AudioTapController(analyzer: analyzer)
        let playback = PlaybackController()
        let auth = AuthController(client: client)
        let likes = LikesController(client: client, auth: auth)

        self.analyzer = analyzer
        self.client = client
        self.audioTap = audioTap
        self.playback = playback
        self.auth = auth
        self.likes = likes
        reposts = RepostsController(client: client, auth: auth)
        playlists = PlaylistsController(client: client, auth: auth)
        feed = FeedController(client: client, auth: auth)
        artworkLoader = ArtworkLoader(client: client)

        playback.onReadyToPlay = { [weak audioTap] in
            Task { @MainActor in
                await audioTap?.startForCurrentProcess()
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
        likesObservation = likes.$tracks.dropFirst().sink { [weak self] tracks in
            guard let self, queue.source == .likes else { return }
            prefetchNextTrack(likedTracks: tracks)
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        if let configurationError {
            errorMessage = configurationError.localizedDescription
            return
        }
        await auth.restore()
        if case .signedIn = auth.state {
            await likes.restoreCache()
            await restorePlayback()
        }
    }

    func signIn() async {
        guard configurationError == nil else {
            errorMessage = configurationError?.localizedDescription
            return
        }
        errorMessage = nil
        await auth.signIn()
        if case .signedIn = auth.state {
            await likes.restoreCache()
            await restorePlayback()
        }
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
        playback.clearSession()
        queue = TrackQueue(source: .single, tracks: [])
        UserDefaults.standard.removeObject(forKey: queueSettingsKey)
        audioTap.stop()
        followingTask?.cancel()
        followingTask = nil
        followingRequestID = nil
        followingOverrides = [:]
        likes.clear()
        reposts.clear()
        playlists.clear()
        feed.clear()
        trackDetailsCache.removeAll()
        artistDetailsCache.removeAll()
        for request in waveformRequests.values { request.task.cancel() }
        waveformRequests.removeAll()
        waveformCache.removeAll()
        latestArtistHeader = nil
        errorMessage = nil
        await auth.signOut()
    }

    func play(_ track: SoundCloudTrack, position: Double = 0) async {
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
        shuffleQueueTask?.cancel()
        trackSelectionTask?.cancel()
        self.queue = queue
        self.queue.replaceLikes(likes.tracks)
        self.queue.setShuffle(playback.isShuffleEnabled, currentURN: track.urn)
        saveQueue()
        if loadRemainingTracks {
            loadRemainingShuffleTracks()
        }
        await loadPlayback(track)
    }

    func continuePlaybackInStation(urn: String, tracks: [SoundCloudTrack], continuingTrackURN: String) {
        guard let currentTrack = playback.currentTrack,
              currentTrack.urn == continuingTrackURN,
              queue.source != .station(urn), !tracks.isEmpty else { return }
        shuffleQueueTask?.cancel()
        trackSelectionTask?.cancel()
        // Keep the current player item and its state. Deduplication leaves the seed first,
        // even when the station omits it or returns it later in the list.
        queue = TrackQueue(source: .station(urn), tracks: [currentTrack] + tracks)
        queue.setShuffle(playback.isShuffleEnabled, currentURN: currentTrack.urn)
        saveQueue()
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
        queue.replaceLikes(likes.tracks)
        queue.setShuffle(playback.isShuffleEnabled, currentURN: playback.currentTrack?.urn)
        guard queue.add(track, after: playback.currentTrack?.urn) else { return }
        shuffleQueueTask?.cancel()
        trackSelectionTask?.cancel()
        saveQueue()
        prefetchNextTrack()
    }

    func removeFromQueue(_ track: SoundCloudTrack) {
        queue.replaceLikes(likes.tracks)
        guard queue.remove(track) else { return }
        shuffleQueueTask?.cancel()
        trackSelectionTask?.cancel()
        saveQueue()
        prefetchNextTrack()
    }

    func clearQueue() {
        shuffleQueueTask?.cancel()
        trackSelectionTask?.cancel()
        queue = TrackQueue(source: .single, tracks: [])
        queue.setShuffle(playback.isShuffleEnabled, currentURN: nil)
        saveQueue()
        prefetchNextTrack()
    }

    func moveQueueTracks(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        queue.replaceLikes(likes.tracks)
        guard queue.move(fromOffsets: offsets, toOffset: destination) else { return }
        shuffleQueueTask?.cancel()
        trackSelectionTask?.cancel()
        saveQueue()
        prefetchNextTrack()
    }

    private func saveQueue() {
        let saved = queue.withoutLikesMetadata()
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: queueSettingsKey)
    }

    private func restorePlayback() async {
        guard playback.currentTrack == nil, playbackTask == nil else { return }
        if let data = UserDefaults.standard.data(forKey: queueSettingsKey),
           let saved = try? JSONDecoder().decode(TrackQueue.self, from: data) {
            queue = saved
        }
        queue.replaceLikes(likes.tracks)
        guard let session = playback.savedSession else { return }
        if queue.source != .likes && !queue.tracks.isEmpty
            && !queue.tracks.contains(where: { $0.urn == session.track.urn }) {
            queue = TrackQueue(source: .single, tracks: [session.track])
        }
        queue.setShuffle(playback.isShuffleEnabled, currentURN: session.track.urn)
        saveQueue()
        await loadPlayback(session.track, position: session.position, autoplay: false)
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
        playbackRequestID = requestID
        errorMessage = nil
        audioTap.stop()
        prefetchNextTrack()

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
                if await playback.loadPrefetched(requestID: requestID) { return }
                try Task.checkCancellation()
                let accessToken = try await auth.validAccessToken()
                try Task.checkCancellation()
                let source = try await client.resolvePlayback(
                    track: track,
                    accessToken: accessToken
                )
                guard !Task.isCancelled,
                      playbackRequestID == requestID else { return }
                playback.load(source: source, requestID: requestID)
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
        let cacheKey = TrackCacheKey(track: track)
        if let cachedDetails = trackDetailsCache.value(forKey: cacheKey) {
            return cachedDetails
        }

        let accessToken = try await auth.validAccessToken()
        let details = try await client.track(
            urn: track.urn,
            secretToken: track.secretToken,
            accessToken: accessToken
        )
        try Task.checkCancellation()
        trackDetailsCache.insert(details, forKey: cacheKey)
        return details
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
        if var details = trackDetailsCache.value(forKey: cacheKey), let count = details.commentCount {
            details.commentCount = count + 1
            trackDetailsCache.insert(details, forKey: cacheKey)
        }
        return comment
    }

    func trackComments(for track: SoundCloudTrack, pageURL: URL? = nil) async throws
        -> SoundCloudCommentPage {
        let accessToken = try await auth.validAccessToken()
        return try await client.trackComments(
            urn: track.urn,
            secretToken: track.secretToken,
            accessToken: accessToken,
            pageURL: pageURL
        )
    }

    func cachedTrackDetails(for track: SoundCloudTrack)
        -> SoundCloudTrackDetails? {
        trackDetailsCache.value(forKey: TrackCacheKey(track: track))
    }

    func cachedArtistDetails(for artist: SoundCloudUser) -> SoundCloudArtistDetails? {
        artistDetailsCache.value(forKey: artist.permalinkURL as NSURL)
    }

    func artistDetails(for artist: SoundCloudUser) async throws -> SoundCloudArtistDetails {
        if let cached = cachedArtistDetails(for: artist) { return cached }
        let accessToken = try await auth.validAccessToken()
        let details = try await client.artist(artist, accessToken: accessToken)
        try Task.checkCancellation()
        artistDetailsCache.insert(details, forKey: artist.permalinkURL as NSURL)
        return details
    }

    func artistWebProfiles(for artist: SoundCloudUser) async throws -> [SoundCloudWebProfile] {
        guard let urn = artist.urn else { throw SoundCloudError.invalidData }
        let accessToken = try await auth.validAccessToken()
        return try await client.artistWebProfiles(urn: urn, accessToken: accessToken)
    }

    func relatedArtists(for artist: SoundCloudUser) async throws -> [SoundCloudUser] {
        guard let urn = artist.urn else { throw SoundCloudError.invalidData }
        let accessToken = try await auth.validAccessToken()
        return try await client.relatedArtists(urn: urn, accessToken: accessToken)
    }

    func isFollowingArtist(_ artist: SoundCloudUser) async throws -> Bool {
        guard let urn = artist.urn else { throw SoundCloudError.invalidData }
        if let followed = followingOverrides[urn] { return followed }
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
            return followingOverrides[urn] ?? followed.contains(urn)
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
        followingOverrides[urn] = isFollowed
        // Refresh follower counts the next time an artist page opens.
        artistDetailsCache.removeAll()
    }

    func cachedArtistHeader(for artist: SoundCloudUser) -> CachedArtistHeader? {
        guard latestArtistHeader?.artistURL == artist.permalinkURL else { return nil }
        return latestArtistHeader
    }

    func artistHeader(for artist: SoundCloudUser) async throws -> CachedArtistHeader? {
        if let cached = cachedArtistHeader(for: artist) { return cached }
        guard let url = try await client.artistHeaderURL(for: artist) else { return nil }
        let data = try await artworkLoader.data(for: url)
        try Task.checkCancellation()
        guard let image = NSImage(data: data) else { throw SoundCloudError.invalidData }
        let header = CachedArtistHeader(
            artistURL: artist.permalinkURL,
            artworkURL: url,
            image: image
        )
        latestArtistHeader = header
        return header
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

    func searchTracks(query: String? = nil, genres: String? = nil, pageURL: URL? = nil) async throws -> SoundCloudTrackPage {
        let accessToken = try await auth.validAccessToken()
        return try await client.searchTracks(query: query, genres: genres, accessToken: accessToken, pageURL: pageURL)
    }

    func searchPlaylists(query: String, pageURL: URL? = nil) async throws -> SoundCloudPlaylistPage {
        let accessToken = try await auth.validAccessToken()
        return try await client.searchPlaylists(query: query, accessToken: accessToken, pageURL: pageURL)
    }

    func searchUsers(query: String, pageURL: URL? = nil) async throws -> SoundCloudUserPage {
        let accessToken = try await auth.validAccessToken()
        return try await client.searchUsers(query: query, accessToken: accessToken, pageURL: pageURL)
    }

    func artistTracks(for artist: SoundCloudUser, pageURL: URL? = nil) async throws
        -> SoundCloudTrackPage {
        guard let urn = artist.urn else { throw SoundCloudError.invalidData }
        let accessToken = try await auth.validAccessToken()
        return try await client.artistTracks(
            urn: urn,
            accessToken: accessToken,
            pageURL: pageURL
        )
    }

    func artistReposts(for artist: SoundCloudUser, pageURL: URL? = nil) async throws
        -> SoundCloudTrackPage {
        guard let urn = artist.urn else { throw SoundCloudError.invalidData }
        let accessToken = try await auth.validAccessToken()
        return try await client.artistReposts(
            urn: urn,
            accessToken: accessToken,
            pageURL: pageURL
        )
    }

    func artistLikes(for artist: SoundCloudUser, pageURL: URL? = nil) async throws
        -> SoundCloudTrackPage {
        guard let urn = artist.urn else { throw SoundCloudError.invalidData }
        let accessToken = try await auth.validAccessToken()
        return try await client.artistLikes(
            urn: urn,
            accessToken: accessToken,
            pageURL: pageURL
        )
    }

    func artistPlaylists(for artist: SoundCloudUser, pageURL: URL? = nil) async throws
        -> SoundCloudPlaylistPage {
        guard let urn = artist.urn else { throw SoundCloudError.invalidData }
        let accessToken = try await auth.validAccessToken()
        return try await client.artistPlaylists(
            urn: urn,
            accessToken: accessToken,
            pageURL: pageURL
        )
    }

    func station(urn: String) async throws -> SoundCloudStation {
        let accessToken = try await auth.validAccessToken()
        return try await client.station(urn: urn, accessToken: accessToken)
    }

    func playlistDetails(for playlist: SoundCloudPlaylist) async throws -> SoundCloudPlaylist {
        let accessToken = try await auth.validAccessToken()
        return try await client.playlist(urn: playlist.urn, accessToken: accessToken)
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

    func recentlyPlayedTracks() async throws -> [SoundCloudTrack] {
        let accessToken = try await auth.validAccessToken()
        return try await client.recentlyPlayedTracks(accessToken: accessToken)
    }

    func relatedTracks(for track: SoundCloudTrack, pageURL: URL? = nil) async throws
        -> SoundCloudTrackPage {
        let accessToken = try await auth.validAccessToken()
        return try await client.relatedTracks(
            urn: track.urn,
            accessToken: accessToken,
            pageURL: pageURL
        )
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
        let cacheKey = waveformURL as NSURL
        if let cachedWaveform = waveformCache.value(forKey: cacheKey) {
            return cachedWaveform
        }

        let request: (id: UUID, task: Task<SoundCloudWaveform, Error>)
        if let existing = waveformRequests[waveformURL] {
            request = existing
        } else {
            request = (UUID(), Task { [client] in
                try await client.waveform(from: waveformURL)
            })
            waveformRequests[waveformURL] = request
        }
        defer {
            if waveformRequests[waveformURL]?.id == request.id {
                waveformRequests[waveformURL] = nil
            }
        }
        let waveform = try await request.task.value
        // A cancelled prefetch may still serve a visible waveform. Sign-out
        // removes the request so an old response cannot repopulate the cache.
        if waveformRequests[waveformURL]?.id == request.id {
            let cost = waveform.samples.count * MemoryLayout<Int>.stride
            waveformCache.insert(waveform, forKey: cacheKey, cost: cost)
        }
        try Task.checkCancellation()
        return waveform
    }

    func cachedWaveform(for track: SoundCloudTrack) -> SoundCloudWaveform? {
        guard let waveformURL = track.waveformURL
            ?? cachedTrackDetails(for: track)?.track.waveformURL else { return nil }
        return waveformCache.value(forKey: waveformURL as NSURL)
    }

    func clearError() {
        errorMessage = nil
    }

    func toggleCurrentTrackLike() {
        guard let track = playback.currentTrack,
              !likes.updatingTrackURNs.contains(track.urn) else { return }
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
        queue.replaceLikes(likes.tracks)
        queue.setShuffle(playback.isShuffleEnabled, currentURN: playback.currentTrack?.urn)
        saveQueue()
        prefetchNextTrack()
    }

    private func prefetchNextTrack(likedTracks: [SoundCloudTrack]? = nil) {
        var resolvedQueue = queue
        resolvedQueue.replaceLikes(likedTracks ?? likes.tracks)
        let currentURN = playback.currentTrack?.urn
        // A sequential page boundary has no known next track yet.
        let needsPage = !playback.isShuffleEnabled && resolvedQueue.needsNextPage(after: currentURN)
        let candidate = currentURN == nil || needsPage ? nil
            : resolvedQueue.relativeTrack(to: currentURN, offset: 1)
        let next = candidate?.urn == currentURN ? nil : candidate
        playback.prefetch(next) { [auth, client] in
            guard let next else { throw CancellationError() }
            let accessToken = try await auth.validAccessToken()
            try Task.checkCancellation()
            return try await client.resolvePlayback(track: next, accessToken: accessToken)
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

    private func prefetchArtwork(for track: SoundCloudTrack) async {
        guard let url = track.displayArtworkURL else { return }
        async let thumbnail = try? artworkLoader.data(for: url, rendition: .square500)
        async let accent = try? artworkLoader.data(for: url)
        _ = await (thumbnail, accent)
    }

    private func selectRelativeTrack(offset: Int, isAutomatic: Bool = false) {
        trackSelectionTask?.cancel()
        trackSelectionTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                // Likes use the disk-backed library, including pages added during playback.
                queue.replaceLikes(likes.tracks)
                if !playback.isShuffleEnabled, offset > 0 {
                    while queue.needsNextPage(after: playback.currentTrack?.urn) {
                        let page = try await nextQueuePage()
                        try Task.checkCancellation()
                        try queue.append(page)
                        saveQueue()
                    }
                }
                try Task.checkCancellation()
                guard let track = queue.relativeTrack(
                    to: playback.currentTrack?.urn,
                    offset: offset,
                    wraps: !isAutomatic || playback.repeatMode == .all
                ) else {
                    if isAutomatic {
                        playback.pause()
                        playback.seek(to: 0)
                    }
                    return
                }
                saveQueue()
                // Queue edits cancel page selection, not the selected stream load.
                trackSelectionTask = nil
                await loadPlayback(track, direction: offset < 0 ? .backward : .forward)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func nextQueuePage() async throws -> SoundCloudTrackPage {
        let source = queue.source
        let pageURL = queue.nextPageURL
        let accessToken = try await auth.validAccessToken()
        try Task.checkCancellation()
        switch source {
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
