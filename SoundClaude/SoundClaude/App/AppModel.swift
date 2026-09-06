import Foundation

@MainActor
final class AppModel: ObservableObject {
    let analyzer: SpectrumAnalyzer
    let audioTap: AudioTapController
    let playback: PlaybackController
    let auth: AuthController
    let likes: LikesController
    let playlists: PlaylistsController
    let artworkLoader: ArtworkLoader

    @Published private(set) var errorMessage: String?

    private let client: SoundCloudClient
    private let configurationError: Error?
    private var playbackTask: Task<Void, Never>?
    private var playbackRequestID: UUID?
    private var trackSelectionTask: Task<Void, Never>?
    private var hasStarted = false
    private var queue = TrackQueue(source: .single, tracks: [])
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
    private let artistDetailsCache = MemoryCache<NSURL, SoundCloudArtistDetails>(countLimit: 100)

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
        playlists = PlaylistsController(client: client, auth: auth)
        artworkLoader = ArtworkLoader(client: client)

        playback.onReadyToPlay = { [weak audioTap] in
            Task { @MainActor in
                await audioTap?.startForCurrentProcess()
            }
        }
        playback.onNext = { [weak self] in
            self?.selectRelativeTrack(offset: 1)
        }
        playback.onPrevious = { [weak self] in
            self?.selectRelativeTrack(offset: -1)
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
        trackSelectionTask?.cancel()
        playbackTask?.cancel()
        playbackTask = nil
        playbackRequestID = nil
        playback.clearSession()
        queue = TrackQueue(source: .single, tracks: [])
        UserDefaults.standard.removeObject(forKey: queueSettingsKey)
        audioTap.stop()
        likes.clear()
        playlists.clear()
        trackDetailsCache.removeAll()
        artistDetailsCache.removeAll()
        waveformCache.removeAll()
        errorMessage = nil
        await auth.signOut()
    }

    func play(_ track: SoundCloudTrack) async {
        // Detail and waveform controls retain an existing list when possible.
        if !queue.tracks.contains(where: { $0.urn == track.urn }),
           !(queue.source == .likes && likes.isLiked(track)) {
            queue = TrackQueue(source: .single, tracks: [track])
        }
        trackSelectionTask?.cancel()
        saveQueue()
        await loadPlayback(track)
    }

    func playLikedTrack(_ track: SoundCloudTrack) async {
        await play(track, queue: TrackQueue(source: .likes, tracks: []))
    }

    func play(_ track: SoundCloudTrack, queue: TrackQueue) async {
        trackSelectionTask?.cancel()
        self.queue = queue
        saveQueue()
        await loadPlayback(track)
    }

    private func saveQueue() {
        var saved = queue
        saved.replaceLikes([]) // Likes metadata already lives in the account cache.
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: queueSettingsKey)
    }

    private func restorePlayback() async {
        guard playback.currentTrack == nil, playbackTask == nil,
              let session = playback.savedSession else { return }
        if let data = UserDefaults.standard.data(forKey: queueSettingsKey),
           let saved = try? JSONDecoder().decode(TrackQueue.self, from: data),
           saved.source == .likes || saved.tracks.contains(where: { $0.urn == session.track.urn }) {
            queue = saved
        } else {
            queue = TrackQueue(source: .single, tracks: [session.track])
        }
        await loadPlayback(session.track, position: session.position, autoplay: false)
    }

    private func loadPlayback(
        _ track: SoundCloudTrack,
        position: Double = 0,
        autoplay: Bool = true
    ) async {
        guard !Task.isCancelled else { return }
        playbackTask?.cancel()
        let requestID = UUID()
        playbackRequestID = requestID
        errorMessage = nil
        audioTap.stop()

        let task = Task { @MainActor in
            defer {
                // An older request must not clear the latest request's task.
                if playbackRequestID == requestID {
                    playbackTask = nil
                    playbackRequestID = nil
                }
            }
            do {
                try Task.checkCancellation()
                let accessToken = try await auth.validAccessToken()
                try Task.checkCancellation()
                let source = try await client.resolvePlayback(
                    track: track,
                    accessToken: accessToken
                )
                guard !Task.isCancelled,
                      playbackRequestID == requestID else { return }
                playback.load(
                    track: track,
                    source: source,
                    position: position,
                    autoplay: autoplay
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      playbackRequestID == requestID else { return }
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
        trackDetailsCache.insert(details, forKey: cacheKey)
        return details
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

        let waveform = try await client.waveform(from: waveformURL)
        let cost = waveform.samples.count * MemoryLayout<Int>.stride
        waveformCache.insert(waveform, forKey: cacheKey, cost: cost)
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

    func toggleShuffle() {
        trackSelectionTask?.cancel()
        playback.toggleShuffle()
        queue.resetShuffle()
        saveQueue()
    }

    private func selectRelativeTrack(offset: Int) {
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
                    shuffle: playback.isShuffleEnabled
                ) else { return }
                saveQueue()
                await loadPlayback(track)
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
        case let .artist(urn):
            return try await client.artistTracks(urn: urn, accessToken: accessToken, pageURL: pageURL)
        case let .playlist(urn):
            return try await client.playlistTracks(urn: urn, accessToken: accessToken, pageURL: pageURL)
        case let .related(urn):
            return try await client.relatedTracks(urn: urn, accessToken: accessToken, pageURL: pageURL)
        case .likes, .single:
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
