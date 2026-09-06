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
    private var shufflePreparationTask: Task<Void, Never>?
    private var trackSelectionTask: Task<Void, Never>?
    private var hasStarted = false
    private var shuffledTrackURNs: [String] = []
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
            await restorePlayback()
            await likes.loadLikedTracks()
            prepareShuffle()
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
            await restorePlayback()
            await likes.loadLikedTracks()
            prepareShuffle()
        }
    }

    func signOut() async {
        shufflePreparationTask?.cancel()
        trackSelectionTask?.cancel()
        playbackTask?.cancel()
        playbackTask = nil
        playbackRequestID = nil
        playback.clearSession()
        shuffledTrackURNs.removeAll()
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
        trackSelectionTask?.cancel()
        await loadPlayback(track)
    }

    private func restorePlayback() async {
        guard playback.currentTrack == nil, playbackTask == nil,
              let session = playback.savedSession else { return }
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
        shufflePreparationTask?.cancel()
        trackSelectionTask?.cancel()
        likes.cancelLoadingAllTracks()
        playback.toggleShuffle()
        shuffledTrackURNs.removeAll()
        prepareShuffle()
    }

    private func prepareShuffle() {
        guard playback.isShuffleEnabled else { return }
        shufflePreparationTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            // LikesController exposes failures so the user can retry with Next.
            try? await likes.loadAllTracks()
        }
    }

    private func selectRelativeTrack(offset: Int) {
        trackSelectionTask?.cancel()
        trackSelectionTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            if playback.isShuffleEnabled {
                do {
                    try await likes.loadAllTracks()
                } catch {
                    // Never shuffle a partial collection after a failed page.
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await selectLoadedRelativeTrack(offset: offset)
        }
    }

    private func selectLoadedRelativeTrack(offset: Int) async {
        guard !likes.tracks.isEmpty else { return }
        let tracks: [SoundCloudTrack]
        if playback.isShuffleEnabled {
            let likedURNs = Set(likes.tracks.map(\.urn))
            shuffledTrackURNs.removeAll { !likedURNs.contains($0) }
            let existingURNs = Set(shuffledTrackURNs)
            var addedURNs = likes.tracks.map(\.urn)
                .filter { !existingURNs.contains($0) }
                .shuffled()
            // Start a new shuffle cycle at the current track.
            if shuffledTrackURNs.isEmpty,
               let currentURN = playback.currentTrack?.urn,
               let index = addedURNs.firstIndex(of: currentURN) {
                addedURNs.remove(at: index)
                addedURNs.insert(currentURN, at: 0)
            }
            // Keep the existing order as more likes load or tracks are unliked.
            shuffledTrackURNs.append(contentsOf: addedURNs)
            let tracksByURN = Dictionary(
                likes.tracks.map { ($0.urn, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            tracks = shuffledTrackURNs.compactMap { tracksByURN[$0] }
        } else {
            tracks = likes.tracks
        }
        let currentIndex = playback.currentTrack.flatMap { current in
            tracks.firstIndex(where: { $0.urn == current.urn })
        } ?? (offset > 0 ? -1 : 0)
        let nextIndex = (currentIndex + offset + tracks.count) % tracks.count
        let track = tracks[nextIndex]
        await loadPlayback(track)
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
