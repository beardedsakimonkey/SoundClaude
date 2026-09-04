import AVFoundation
import Foundation

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var currentTrack: SoundCloudTrack?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?
    @Published var volume: Float = 1 {
        didSet { player.volume = volume }
    }
    @Published var isMuted = false {
        didSet { player.isMuted = isMuted }
    }

    let player: AVPlayer
    var onReadyToPlay: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    private var itemStatusObservation: NSKeyValueObservation?
    private var playerStatusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init() {
        player = AVPlayer()
        player.preventsDisplaySleepDuringVideoPlayback = false
        playerStatusObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                currentTime = time.seconds.isFinite ? time.seconds : 0
                let itemDuration = player.currentItem?.duration.seconds ?? 0
                duration = itemDuration.isFinite ? itemDuration : 0
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
    }

    func load(track: SoundCloudTrack, source: PlaybackSource) {
        pause()
        itemStatusObservation?.invalidate()
        errorMessage = nil
        currentTrack = track
        currentTime = 0
        duration = Double(track.durationMilliseconds) / 1_000
        isLoading = true

        let item = AVPlayerItem(url: source.url)
        player.replaceCurrentItem(with: item)
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
                    player.play()
                    onReadyToPlay?()
                case .failed:
                    isLoading = false
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
        guard seconds.isFinite else { return }
        let upperBound = duration > 0 ? duration : seconds
        let target = min(max(seconds, 0), upperBound)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
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
}
