import AVFoundation
import Foundation
@preconcurrency import MediaPlayer
import Observation

private struct RemoteCommandTarget: @unchecked Sendable {
    let command: MPRemoteCommand
    let target: Any
}

struct SavedPlayback: Codable {
    let track: SoundCloudTrack
    let position: Double
}

@MainActor
@Observable
final class PlaybackController {
    enum RepeatMode: String {
        case off, all, one

        var label: String {
            switch self {
            case .off: "Off"
            case .all: "Repeat all"
            case .one: "Repeat one"
            }
        }

        var nextAction: String {
            switch self {
            case .off: "Repeat all tracks"
            case .all: "Repeat current track"
            case .one: "Turn repeat off"
            }
        }
    }

    private(set) var repeatMode: RepeatMode = .off {
        didSet {
            defaults.set(repeatMode.rawValue, forKey: SettingsKey.repeatMode)
        }
    }
    enum TrackChangeDirection {
        case forward, backward
    }

    private(set) var trackChangeDirection: TrackChangeDirection = .forward
    private(set) var currentTrack: SoundCloudTrack?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private var isWaitingForPlayback = false

    var isBuffering: Bool {
        currentTrack != nil && errorMessage == nil && !isLoading
            && (isSeekInProgress || (shouldPlayWhenReady && isWaitingForPlayback))
    }
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var errorMessage: String?
    private(set) var isShuffleEnabled = false {
        didSet {
            defaults.set(isShuffleEnabled, forKey: SettingsKey.isShuffleEnabled)
        }
    }
    var volume: Float = 1 {
        didSet {
            player.volume = volume
            defaults.set(volume, forKey: SettingsKey.volume)
        }
    }
    var isMuted = false {
        didSet {
            player.isMuted = isMuted
            defaults.set(isMuted, forKey: SettingsKey.isMuted)
        }
    }

    private enum SettingsKey {
        static let volume = "playback.volume"
        static let isMuted = "playback.isMuted"
        static let isShuffleEnabled = "playback.isShuffleEnabled"
        static let repeatMode = "playback.repeatMode"
        static let session = "playback.session"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makePrefetchPlayer: @MainActor (URL) -> AVPlayer
    @ObservationIgnored private(set) var player: AVPlayer
    @ObservationIgnored var onReadyToPlay: (() -> Void)?
    @ObservationIgnored var onTrackEnded: (() -> Void)?
    @ObservationIgnored var onNext: (() -> Void)?
    @ObservationIgnored var onPrevious: (() -> Void)?

    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var playerStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var seekTarget: Double?
    private var isSeekInProgress = false
    @ObservationIgnored private var loadingRequestID: UUID?
    private struct Preparation {
        let id: UUID
        let track: SoundCloudTrack
        let task: Task<AVPlayer, Error>
        var player: AVPlayer?
    }

    @ObservationIgnored private var preparationObservation: NSKeyValueObservation?
    @ObservationIgnored private var nextPreparation: Preparation?
    @ObservationIgnored private var loadingPreparation: Preparation?
    private var shouldPlayWhenReady = false
    @ObservationIgnored private var hasNotifiedReady = false
    @ObservationIgnored private var lastSaveTime = Date.distantPast
    private let remoteCommandCenter = MPRemoteCommandCenter.shared()
    @ObservationIgnored private var remoteCommandTargets: [RemoteCommandTarget] = []

    init(
        defaults: UserDefaults = .standard,
        makePrefetchPlayer: @escaping @MainActor (URL) -> AVPlayer = { AVPlayer(url: $0) }
    ) {
        self.defaults = defaults
        self.makePrefetchPlayer = makePrefetchPlayer
        defaults.register(defaults: [
            SettingsKey.volume: Float(1),
            SettingsKey.isMuted: false,
            SettingsKey.isShuffleEnabled: false,
        ])
        let savedVolume = defaults.float(forKey: SettingsKey.volume)
        volume = savedVolume.isFinite ? min(max(savedVolume, 0), 1) : 1
        isMuted = defaults.bool(forKey: SettingsKey.isMuted)
        isShuffleEnabled = defaults.bool(forKey: SettingsKey.isShuffleEnabled)
        repeatMode = RepeatMode(rawValue: defaults.string(forKey: SettingsKey.repeatMode) ?? "") ?? .off
        player = AVPlayer()
        player.volume = volume
        player.isMuted = isMuted
        player.preventsDisplaySleepDuringVideoPlayback = false
        observePlayer()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self,
                      notification.object as? AVPlayerItem === player.currentItem else {
                    return
                }
                if repeatMode == .one {
                    seek(to: 0)
                    play()
                } else {
                    shouldPlayWhenReady = false
                    isPlaying = false
                    updateNowPlayingInfo()
                    onTrackEnded?()
                }
            }
        }
        configureRemoteCommands()
        updateRemoteCommandAvailability()
    }

    deinit {
        nextPreparation?.task.cancel()
        loadingPreparation?.task.cancel()
        preparationObservation?.invalidate()
        itemStatusObservation?.invalidate()
        playerStatusObservation?.invalidate()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        for target in remoteCommandTargets {
            target.command.removeTarget(target.target)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func observePlayer() {
        playerStatusObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player === player else { return }
                isPlaying = player.timeControlStatus == .playing
                isWaitingForPlayback = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                updateNowPlayingInfo()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if seekTarget == nil, let item = player.currentItem, item.status != .failed {
                    let seconds = player.currentTime().seconds
                    currentTime = seconds.isFinite ? seconds : 0
                }
                let itemDuration = player.currentItem?.duration.seconds ?? 0
                let updatedDuration = itemDuration.isFinite && itemDuration > 0
                    ? itemDuration : duration
                if duration != updatedDuration {
                    duration = updatedDuration
                }
                if Date().timeIntervalSince(lastSaveTime) >= 5 {
                    saveSession()
                }
            }
        }
    }

    private func replacePlayer(with prepared: AVPlayer) {
        playerStatusObservation?.invalidate()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        player.replaceCurrentItem(with: nil)
        player = prepared
        isWaitingForPlayback = false
        player.cancelPendingPrerolls()
        player.volume = volume
        player.isMuted = isMuted
        player.preventsDisplaySleepDuringVideoPlayback = false
        observePlayer()
    }

    var savedSession: SavedPlayback? {
        guard let data = defaults.data(forKey: SettingsKey.session),
              let session = try? JSONDecoder().decode(SavedPlayback.self, from: data),
              session.position.isFinite, session.position >= 0 else { return nil }
        return session
    }

    func saveSession() {
        guard let track = currentTrack,
              player.currentItem?.status != .failed else { return }
        let seconds = seekTarget ?? (player.currentItem == nil ? currentTime : player.currentTime().seconds)
        let position = seconds.isFinite ? max(seconds, 0) : currentTime
        let session = SavedPlayback(track: track, position: position)
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: SettingsKey.session)
        lastSaveTime = Date()
    }

    func clearSession() {
        pause()
        discardNextPreparation()
        loadingPreparation?.task.cancel()
        loadingPreparation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        loadingRequestID = nil
        player.replaceCurrentItem(with: nil)
        currentTrack = nil
        currentTime = 0
        duration = 0
        seekTarget = nil
        isSeekInProgress = false
        isLoading = false
        isPlaying = false
        isWaitingForPlayback = false
        errorMessage = nil
        defaults.removeObject(forKey: SettingsKey.session)
        updateNowPlayingInfo()
        updateRemoteCommandAvailability()
    }

    @discardableResult
    func beginLoading(
        track: SoundCloudTrack,
        position: Double = 0,
        autoplay: Bool = true,
        direction: TrackChangeDirection = .forward
    ) -> UUID {
        pause()
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        loadingPreparation?.task.cancel()
        loadingPreparation = nil
        if let next = nextPreparation,
           matches(next, track: track),
           next.player?.currentItem?.status != .failed {
            preparationObservation?.invalidate()
            preparationObservation = nil
            loadingPreparation = next
            nextPreparation = nil
        } else {
            discardNextPreparation()
        }
        player.replaceCurrentItem(with: nil)
        let requestID = UUID()
        loadingRequestID = requestID
        seekTarget = nil
        isSeekInProgress = false
        hasNotifiedReady = false
        errorMessage = nil
        trackChangeDirection = direction
        currentTrack = track
        duration = Double(track.durationMilliseconds) / 1_000
        let safePosition = position.isFinite ? max(position, 0) : 0
        currentTime = duration > 0 ? min(safePosition, duration) : safePosition
        seekTarget = currentTime
        shouldPlayWhenReady = autoplay
        isLoading = true
        isPlaying = false
        isWaitingForPlayback = false
        updateNowPlayingInfo(elapsedTime: currentTime)
        saveSession()
        updateRemoteCommandAvailability()
        if let prepared = loadingPreparation?.player {
            loadingPreparation = nil
            load(prepared: prepared, requestID: requestID)
        }
        return requestID
    }

    /// Prepare one silent standby player, then reuse it when Next selects its track.
    func prefetch(
        _ track: SoundCloudTrack?,
        resolve: @escaping @MainActor () async throws -> PlaybackSource
    ) {
        if let track, let next = nextPreparation,
           matches(next, track: track), next.player?.currentItem?.status != .failed { return }
        discardNextPreparation()
        guard let track else { return }
        let id = UUID()
        let makePlayer = makePrefetchPlayer
        let task = Task { @MainActor [weak self] in
            let source = try await resolve()
            try Task.checkCancellation()
            let prepared = makePlayer(source.url)
            prepared.isMuted = true
            prepared.preventsDisplaySleepDuringVideoPlayback = false
            if let self, nextPreparation?.id == id {
                nextPreparation?.player = prepared
                prepareBuffer(for: prepared, id: id)
            }
            return prepared
        }
        nextPreparation = Preparation(id: id, track: track, task: task)
    }

    /// Share an unfinished resolution with Next; failures fall back to a fresh request.
    func loadPrefetched(requestID: UUID) async -> Bool {
        guard loadingRequestID == requestID else { return true }
        guard let preparation = loadingPreparation else { return false }
        defer {
            if loadingPreparation?.id == preparation.id { loadingPreparation = nil }
        }
        do {
            let prepared = try await preparation.task.value
            guard !Task.isCancelled, loadingRequestID == requestID else { return true }
            guard prepared.currentItem?.status != .failed else { return false }
            load(prepared: prepared, requestID: requestID)
            return true
        } catch {
            return Task.isCancelled || loadingRequestID != requestID
        }
    }

    private func matches(_ preparation: Preparation, track: SoundCloudTrack) -> Bool {
        preparation.track.urn == track.urn
            && preparation.track.secretToken == track.secretToken
    }

    private func discardNextPreparation() {
        preparationObservation?.invalidate()
        preparationObservation = nil
        nextPreparation?.task.cancel()
        nextPreparation?.player?.cancelPendingPrerolls()
        nextPreparation?.player?.replaceCurrentItem(with: nil)
        nextPreparation = nil
    }

    private func prepareBuffer(for prepared: AVPlayer, id: UUID) {
        preparationObservation = prepared.currentItem?.observe(
            \.status, options: [.initial, .new]
        ) { [weak self, weak prepared] _, _ in
            Task { @MainActor [weak self, weak prepared] in
                guard let self, let prepared, nextPreparation?.id == id,
                      prepared.currentItem?.status == .readyToPlay else { return }
                preparationObservation?.invalidate()
                preparationObservation = nil
                prepared.preroll(atRate: 1) { _ in }
            }
        }
    }

    private func load(prepared: AVPlayer, requestID: UUID) {
        guard loadingRequestID == requestID, let item = prepared.currentItem else { return }
        replacePlayer(with: prepared)
        // A fresh standby player is already at the start. Preserve its preroll
        // instead of issuing a redundant seek before playback.
        if seekTarget == 0, prepared.currentTime().seconds == 0 {
            seekTarget = nil
        }
        load(item: item, requestID: requestID)
    }

    func load(source: PlaybackSource, requestID: UUID) {
        guard loadingRequestID == requestID else { return }
        load(item: AVPlayerItem(url: source.url), requestID: requestID)
    }

    private func load(item: AVPlayerItem, requestID: UUID) {
        guard loadingRequestID == requestID else { return }
        loadingRequestID = nil
        if player.currentItem !== item {
            player.replaceCurrentItem(with: item)
        }
        saveSession()
        updateRemoteCommandAvailability()
        itemStatusObservation = item.observe(
            \.status,
            options: [.new]
        ) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item else { return }
                updateItemStatus(item)
            }
        }
        // A prepared item can already be ready. Avoid a loading flash while
        // waiting for an asynchronous observation callback.
        updateItemStatus(item)
    }

    private func updateItemStatus(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            isLoading = false
            seekIfNeeded()
            playIfReady()
        case .failed:
            isLoading = false
            shouldPlayWhenReady = false
            errorMessage = item.error?.localizedDescription
                ?? "The track could not be played."
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    func failLoading(requestID: UUID, message: String? = nil) {
        guard loadingRequestID == requestID else { return }
        loadingRequestID = nil
        isLoading = false
        shouldPlayWhenReady = false
        errorMessage = message
        updateNowPlayingInfo(elapsedTime: currentTime)
    }

    // Keep transport controls stable while playback loads, seeks, or buffers.
    var isPlaybackActive: Bool {
        isPlaying || shouldPlayWhenReady
    }

    func togglePlayPause() {
        if isPlaybackActive {
            pause()
        } else if isLoading || player.currentItem != nil {
            play()
        }
    }

    private func play() {
        guard isLoading || player.currentItem != nil else { return }
        shouldPlayWhenReady = true
        playIfReady()
    }

    private func playIfReady() {
        guard shouldPlayWhenReady, seekTarget == nil, !isSeekInProgress,
              player.currentItem?.status == .readyToPlay else { return }
        player.play()
        if !hasNotifiedReady {
            hasNotifiedReady = true
            onReadyToPlay?()
        }
    }

    func pause() {
        shouldPlayWhenReady = false
        player.pause()
        saveSession()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite,
              currentTrack != nil,
              isLoading || player.currentItem != nil,
              player.currentItem?.status != .failed else { return }
        let upperBound = duration > 0 ? duration : seconds
        let target = min(max(seconds, 0), upperBound)
        seekTarget = target
        currentTime = target
        updateNowPlayingInfo(elapsedTime: target)
        saveSession()
        seekIfNeeded()
    }

    func seek(by offset: Double) {
        seek(to: currentTime + offset)
    }

    func toggleMute() {
        isMuted.toggle()
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    func next() {
        onNext?()
    }

    func previous() {
        if currentTime > 3 {
            seek(to: 0)
        } else {
            onPrevious?()
        }
    }

    private func seekIfNeeded() {
        guard !isSeekInProgress,
              let requestedTarget = seekTarget,
              let item = player.currentItem,
              item.status == .readyToPlay else { return }

        let itemDuration = item.duration.seconds
        let target = itemDuration.isFinite && itemDuration > 0
            ? min(requestedTarget, itemDuration) : requestedTarget
        seekTarget = target
        currentTime = target

        // Let this seek finish while newer requests replace only the target.
        isSeekInProgress = true
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, item === player.currentItem else {
                    return
                }
                isSeekInProgress = false
                if let latestTarget = seekTarget, latestTarget != target {
                    seekIfNeeded()
                } else {
                    seekTarget = nil
                    let seconds = player.currentTime().seconds
                    currentTime = seconds.isFinite ? seconds : 0
                    updateNowPlayingInfo()
                    saveSession()
                    playIfReady()
                }
            }
        }
    }

    private func configureRemoteCommands() {
        addRemoteTarget(to: remoteCommandCenter.playCommand) {
            controller,
            _ in
            controller.play()
        }
        addRemoteTarget(to: remoteCommandCenter.pauseCommand) {
            controller,
            _ in
            controller.pause()
        }
        addRemoteTarget(
            to: remoteCommandCenter.togglePlayPauseCommand
        ) { controller, _ in
            controller.togglePlayPause()
        }
        addRemoteTarget(
            to: remoteCommandCenter.previousTrackCommand
        ) { controller, _ in
            controller.previous()
        }
        addRemoteTarget(to: remoteCommandCenter.nextTrackCommand) {
            controller,
            _ in
            controller.next()
        }

        remoteCommandCenter.skipBackwardCommand.preferredIntervals = [5]
        addRemoteTarget(to: remoteCommandCenter.skipBackwardCommand) {
            controller,
            event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 5
            controller.seek(by: -interval)
        }

        remoteCommandCenter.skipForwardCommand.preferredIntervals = [5]
        addRemoteTarget(to: remoteCommandCenter.skipForwardCommand) {
            controller,
            event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 5
            controller.seek(by: interval)
        }

        addRemoteTarget(
            to: remoteCommandCenter.changePlaybackPositionCommand
        ) { controller, event in
            guard let positionEvent = event
                as? MPChangePlaybackPositionCommandEvent else {
                return
            }
            controller.seek(to: positionEvent.positionTime)
        }
    }

    private func addRemoteTarget(
        to command: MPRemoteCommand,
        handler: @escaping @MainActor (
            PlaybackController,
            MPRemoteCommandEvent
        ) -> Void
    ) {
        let target = command.addTarget { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                handler(self, event)
            }
            return .success
        }
        remoteCommandTargets.append(
            RemoteCommandTarget(command: command, target: target)
        )
    }

    private func updateRemoteCommandAvailability() {
        let hasTrack = currentTrack != nil
        remoteCommandCenter.playCommand.isEnabled = hasTrack
        remoteCommandCenter.pauseCommand.isEnabled = hasTrack
        remoteCommandCenter.togglePlayPauseCommand.isEnabled = hasTrack
        remoteCommandCenter.previousTrackCommand.isEnabled = hasTrack
        remoteCommandCenter.nextTrackCommand.isEnabled = hasTrack
        remoteCommandCenter.skipBackwardCommand.isEnabled = hasTrack
        remoteCommandCenter.skipForwardCommand.isEnabled = hasTrack
        remoteCommandCenter.changePlaybackPositionCommand.isEnabled = hasTrack
    }

    private func updateNowPlayingInfo(elapsedTime: Double? = nil) {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }

        let playbackTime = elapsedTime ?? seekTarget ?? player.currentTime().seconds
        let safePlaybackTime = playbackTime.isFinite ? playbackTime : 0
        let isPlayerPlaying = player.timeControlStatus == .playing
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.uploader,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: safePlaybackTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlayerPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: track.urn,
            MPNowPlayingInfoPropertyServiceIdentifier: "SoundCloud",
        ]
        MPNowPlayingInfoCenter.default().playbackState = isPlayerPlaying
            ? .playing
            : .paused
    }
}
