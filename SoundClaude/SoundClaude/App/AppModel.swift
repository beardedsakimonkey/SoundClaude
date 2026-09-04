import Foundation

@MainActor
final class AppModel: ObservableObject {
    let analyzer: SpectrumAnalyzer
    let audioTap: AudioTapController
    let playback: PlaybackController
    let auth: AuthController
    let library: LibraryController
    let artworkLoader: ArtworkLoader

    @Published private(set) var errorMessage: String?

    private let client: SoundCloudClient
    private let configurationError: Error?
    // These limits leave room for the 10-track library and bound future growth.
    private let trackDetailsCache = MemoryCache<
        TrackCacheKey,
        SoundCloudTrackDetails
    >(countLimit: 100)
    private let waveformCache = MemoryCache<
        NSURL,
        SoundCloudWaveform
    >(countLimit: 50, totalCostLimit: 8 * 1_024 * 1_024)

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
        let library = LibraryController(client: client, auth: auth)

        self.analyzer = analyzer
        self.client = client
        self.audioTap = audioTap
        self.playback = playback
        self.auth = auth
        self.library = library
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
        if let configurationError {
            errorMessage = configurationError.localizedDescription
            return
        }
        await auth.restore()
        if case .signedIn = auth.state {
            await library.loadLikedTracks()
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
            await library.loadLikedTracks()
        }
    }

    func signOut() async {
        playback.pause()
        audioTap.stop()
        library.clear()
        trackDetailsCache.removeAll()
        waveformCache.removeAll()
        errorMessage = nil
        await auth.signOut()
    }

    func play(_ track: SoundCloudTrack) async {
        errorMessage = nil
        audioTap.stop()
        do {
            let accessToken = try await auth.validAccessToken()
            let source = try await client.resolvePlayback(
                track: track,
                accessToken: accessToken
            )
            playback.load(track: track, source: source)
        } catch {
            errorMessage = error.localizedDescription
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

    func waveform(for track: SoundCloudTrack) async throws
        -> SoundCloudWaveform {
        guard let waveformURL = track.waveformURL else {
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
        guard let waveformURL = track.waveformURL else { return nil }
        return waveformCache.value(forKey: waveformURL as NSURL)
    }

    func clearError() {
        errorMessage = nil
    }

    private func selectRelativeTrack(offset: Int) {
        guard !library.tracks.isEmpty else { return }
        let currentIndex = playback.currentTrack.flatMap { current in
            library.tracks.firstIndex(where: { $0.urn == current.urn })
        } ?? (offset > 0 ? -1 : 0)
        let nextIndex = (currentIndex + offset + library.tracks.count)
            % library.tracks.count
        let track = library.tracks[nextIndex]
        Task { @MainActor [weak self] in
            await self?.play(track)
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
