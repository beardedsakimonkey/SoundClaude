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
        let accessToken = try await auth.validAccessToken()
        return try await client.track(
            urn: track.urn,
            secretToken: track.secretToken,
            accessToken: accessToken
        )
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
