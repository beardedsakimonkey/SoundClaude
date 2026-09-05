import AVFoundation
import Foundation
@preconcurrency import MediaPlayer
import Observation

private struct RemoteCommandTarget: @unchecked Sendable {
    let command: MPRemoteCommand
    let target: Any
}

@MainActor
@Observable
final class PlaybackController {
    private(set) var currentTrack: SoundCloudTrack?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var errorMessage: String?
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
    }

    @ObservationIgnored private let defaults: UserDefaults
    let player: AVPlayer
    @ObservationIgnored var onReadyToPlay: (() -> Void)?
    @ObservationIgnored var onNext: (() -> Void)?
    @ObservationIgnored var onPrevious: (() -> Void)?

    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var playerStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var seekTarget: Double?
    @ObservationIgnored private var isSeekInProgress = false
    private let remoteCommandCenter = MPRemoteCommandCenter.shared()
    @ObservationIgnored private var remoteCommandTargets: [RemoteCommandTarget] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            SettingsKey.volume: Float(1),
            SettingsKey.isMuted: false,
        ])
        let savedVolume = defaults.float(forKey: SettingsKey.volume)
        volume = savedVolume.isFinite ? min(max(savedVolume, 0), 1) : 1
        isMuted = defaults.bool(forKey: SettingsKey.isMuted)
        player = AVPlayer()
        player.volume = volume
        player.isMuted = isMuted
        player.preventsDisplaySleepDuringVideoPlayback = false
        playerStatusObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isPlaying = player.timeControlStatus == .playing
                updateNowPlayingInfo()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if seekTarget == nil {
                    let seconds = player.currentTime().seconds
                    currentTime = seconds.isFinite ? seconds : 0
                }
                let itemDuration = player.currentItem?.duration.seconds ?? 0
                let updatedDuration = itemDuration.isFinite ? itemDuration : 0
                if duration != updatedDuration {
                    duration = updatedDuration
                }
            }
        }
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
                onNext?()
            }
        }
        configureRemoteCommands()
        updateRemoteCommandAvailability()
    }

    deinit {
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

    func load(track: SoundCloudTrack, source: PlaybackSource) {
        pause()
        itemStatusObservation?.invalidate()
        seekTarget = nil
        isSeekInProgress = false
        errorMessage = nil
        currentTrack = track
        currentTime = 0
        duration = Double(track.durationMilliseconds) / 1_000
        isLoading = true
        updateNowPlayingInfo(elapsedTime: 0)

        let item = AVPlayerItem(url: source.url)
        player.replaceCurrentItem(with: item)
        updateRemoteCommandAvailability()
        itemStatusObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, item === player.currentItem else {
                    return
                }
                switch item.status {
                case .readyToPlay:
                    isLoading = false
                    seekIfNeeded()
                    player.play()
                    onReadyToPlay?()
                case .failed:
                    isLoading = false
                    seekTarget = nil
                    errorMessage = item.error?.localizedDescription
                        ?? "The track could not be played."
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else if player.currentItem != nil {
            player.play()
        }
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite,
              let item = player.currentItem,
              item.status != .failed else { return }
        let upperBound = duration > 0 ? duration : seconds
        let target = min(max(seconds, 0), upperBound)
        seekTarget = target
        currentTime = target
        updateNowPlayingInfo(elapsedTime: target)
        seekIfNeeded()
    }

    func seek(by offset: Double) {
        seek(to: currentTime + offset)
    }

    func toggleMute() {
        isMuted.toggle()
    }

    func next() {
        onNext?()
    }

    func previous() {
        onPrevious?()
    }

    private func seekIfNeeded() {
        guard !isSeekInProgress,
              let target = seekTarget,
              let item = player.currentItem,
              item.status == .readyToPlay else { return }

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
                }
            }
        }
    }

    private func configureRemoteCommands() {
        addRemoteTarget(to: remoteCommandCenter.playCommand) {
            controller,
            _ in
            controller.player.play()
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
        let hasTrack = player.currentItem != nil
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
