import AVFoundation
import Foundation

// Drive AVPlayer's waiting state without relying on network timing.
private final class BufferingTestPlayer: AVPlayer {
    private var simulatedStatus: AVPlayer.TimeControlStatus?

    override var timeControlStatus: AVPlayer.TimeControlStatus {
        simulatedStatus ?? super.timeControlStatus
    }

    func simulateStatus(_ status: AVPlayer.TimeControlStatus?) {
        willChangeValue(forKey: "timeControlStatus")
        simulatedStatus = status
        didChangeValue(forKey: "timeControlStatus")
    }
}

// Hold stream resolution between beginLoading and load. A local silent file
// tests AVPlayer readiness without credentials, network access, or audio output.
@main
struct PlaybackTests {
    @MainActor
    static func main() async throws {
        let suite = "SoundClaude.PlaybackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preparedPlayers: [AVPlayer] = []
        let playback = PlaybackController(defaults: defaults) { url in
            let player = BufferingTestPlayer(url: url)
            preparedPlayers.append(player)
            return player
        }
        let user = SoundCloudUser(
            urn: "user:1", username: "Test", avatarURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/test")!
        )
        func track(_ id: Int) -> SoundCloudTrack {
            SoundCloudTrack(
                urn: "track:\(id)", title: "Track \(id)", artist: user,
                artworkURL: nil, waveformURL: nil,
                permalinkURL: URL(string: "https://soundcloud.com/test/\(id)")!,
                durationMilliseconds: 2000, access: .playable, secretToken: nil
            )
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try writeSilence(to: fileURL)
        let source = PlaybackSource(
            url: fileURL, kind: .hls, codec: .aac,
            bitrateKilobitsPerSecond: 160, isPreview: false
        )

        // Selection and saved position update before a stream URL is available.
        let first = playback.beginLoading(track: track(1), position: 0.5)
        precondition(playback.currentTrack == track(1))
        precondition(playback.isLoading && playback.isPlaybackActive && !playback.isPlaying)
        precondition(playback.player.currentItem == nil)
        precondition(playback.currentTime == 0.5 && playback.duration == 2)
        precondition(playback.savedSession?.track == track(1))
        precondition(playback.savedSession?.position == 0.5)

        // Pause and seek during resolution must survive source attachment.
        playback.togglePlayPause()
        playback.seek(to: 1)
        precondition(!playback.isPlaybackActive && playback.currentTime == 1)
        playback.load(source: source, requestID: first)
        try await until { !playback.isLoading && abs(playback.player.currentTime().seconds - 1) < 0.05 }
        precondition(!playback.isPlaybackActive && !playback.isPlaying)
        precondition(playback.savedSession?.position == 1)

        // Remove the old item immediately; late status/time callbacks cannot
        // restore its position or duration while the next source is resolving.
        let second = playback.beginLoading(track: track(2))
        precondition(playback.player.currentItem == nil)
        precondition(playback.currentTrack == track(2) && playback.currentTime == 0)
        try await Task.sleep(for: .milliseconds(300))
        precondition(playback.currentTime == 0 && playback.duration == 2)

        // Rapid skips and reverse navigation reject stale completions/failures.
        let third = playback.beginLoading(track: track(3), direction: .backward)
        precondition(playback.trackChangeDirection == .backward)
        playback.load(source: source, requestID: second)
        playback.failLoading(requestID: second, message: "Old failure")
        precondition(playback.currentTrack == track(3) && playback.player.currentItem == nil)
        precondition(playback.isLoading && playback.errorMessage == nil)
        playback.failLoading(requestID: third, message: "Stream unavailable")
        precondition(!playback.isLoading && !playback.isPlaybackActive)
        precondition(playback.errorMessage == "Stream unavailable")
        playback.load(source: source, requestID: third)
        precondition(playback.player.currentItem == nil)

        // A paused restore can be resumed while its stream URL is resolving.
        let restored = playback.beginLoading(track: track(1), position: 0.75, autoplay: false)
        precondition(!playback.isPlaybackActive && playback.errorMessage == nil)
        playback.togglePlayPause()
        precondition(playback.isPlaybackActive)
        playback.pause()
        playback.load(source: source, requestID: restored)
        try await until { !playback.isLoading && abs(playback.player.currentTime().seconds - 0.75) < 0.05 }
        precondition(!playback.isPlaybackActive)

        // Finishing the last track clears playback intent before advancing the queue.
        var didEnd = false
        playback.onTrackEnded = {
            precondition(!playback.isPlaybackActive)
            didEnd = true
        }
        playback.togglePlayPause()
        precondition(playback.isPlaybackActive)
        try await until { didEnd }
        precondition(!playback.isPlaybackActive && !playback.isPlaying)

        // Preparation readies audio without changing the selected track or position.
        let beforePrefetch = playback.beginLoading(track: track(1), autoplay: false)
        playback.load(source: source, requestID: beforePrefetch)
        try await until { !playback.isLoading }
        var resolutions = 0
        playback.prefetch(track(2)) {
            resolutions += 1
            return source
        }
        try await until { preparedPlayers.last?.currentItem?.status == .readyToPlay }
        let preparedPlayer = preparedPlayers.last!
        let preparedItem = preparedPlayer.currentItem!
        precondition(preparedPlayer.isMuted && preparedPlayer.rate == 0)
        precondition(playback.currentTrack == track(1))
        precondition(playback.savedSession?.track == track(1))
        precondition(!playback.isPlaybackActive && playback.player.rate == 0)
        playback.prefetch(track(2)) {
            fatalError("An unchanged next track must share preparation")
        }
        playback.volume = 0.37
        let preparedSelection = playback.beginLoading(track: track(2), autoplay: false)
        precondition(!playback.isLoading)
        precondition(playback.player === preparedPlayer)
        precondition(playback.player.isMuted == playback.isMuted)
        precondition(playback.player.volume == 0.37)
        let reused = await playback.loadPrefetched(requestID: preparedSelection)
        precondition(reused && resolutions == 1)
        precondition(playback.player.currentItem === preparedItem)
        try await until { !playback.isLoading }
        precondition(playback.currentTime == 0 && !playback.isPlaybackActive)

        // A pending seek pulses even while paused, then clears on completion.
        playback.seek(to: 0.5)
        precondition(playback.isBuffering && !playback.isLoading)
        try await until { !playback.isBuffering }
        precondition(abs(playback.currentTime - 0.5) < 0.05)
        precondition(!playback.isPlaybackActive)

        // Buffering after readiness pulses until playback resumes. Pausing
        // clears the indicator even before the player's status callback.
        let bufferingPlayer = preparedPlayer as! BufferingTestPlayer
        playback.togglePlayPause()
        bufferingPlayer.simulateStatus(.waitingToPlayAtSpecifiedRate)
        try await until { playback.isBuffering }
        precondition(!playback.isLoading)
        playback.pause()
        precondition(!playback.isBuffering)
        playback.togglePlayPause()
        try await until { playback.isBuffering }
        bufferingPlayer.simulateStatus(.playing)
        try await until { !playback.isBuffering && playback.isPlaying }
        playback.pause()
        bufferingPlayer.simulateStatus(nil)

        // Queue edits drop an obsolete player and retain only the new next track.
        playback.prefetch(track(3)) { source }
        try await until { preparedPlayers.count == 2 }
        let discardedPlayer = preparedPlayers.last!
        playback.prefetch(track(4)) { source }
        precondition(discardedPlayer.currentItem == nil)
        try await until { preparedPlayers.count == 3 }
        let clearedPlayer = preparedPlayers.last!
        playback.prefetch(nil) { fatalError("An empty queue must not resolve audio") }
        precondition(clearedPlayer.currentItem == nil)

        // Next can consume an in-flight resolution even while the following
        // track is prepared. Pause and seek still apply before attachment.
        var releaseResolution: CheckedContinuation<Void, Never>?
        playback.prefetch(track(3)) {
            resolutions += 1
            await withCheckedContinuation { releaseResolution = $0 }
            return source
        }
        try await until { releaseResolution != nil }
        let inFlight = playback.beginLoading(track: track(3))
        playback.prefetch(track(4)) { source }
        playback.pause()
        playback.seek(to: 0.5)
        releaseResolution?.resume()
        let sharedResolution = await playback.loadPrefetched(requestID: inFlight)
        precondition(sharedResolution)
        try await until { !playback.isLoading && abs(playback.player.currentTime().seconds - 0.5) < 0.05 }
        precondition(resolutions == 2 && !playback.isPlaybackActive)
        try await until { preparedPlayers.count == 5 }

        // An unfinished preparation cannot attach after a second skip.
        playback.prefetch(track(5)) {
            await withCheckedContinuation { releaseResolution = $0 }
            return source
        }
        releaseResolution = nil
        try await until { releaseResolution != nil }
        let skipped = playback.beginLoading(track: track(5))
        let skippedLoad = Task { await playback.loadPrefetched(requestID: skipped) }
        await Task.yield()
        let latest = playback.beginLoading(track: track(6), autoplay: false)
        releaseResolution?.resume()
        let ignoredSkip = await skippedLoad.value
        precondition(ignoredSkip)
        precondition(playback.currentTrack == track(6) && playback.player.currentItem == nil)
        let latestHasPreparation = await playback.loadPrefetched(requestID: latest)
        precondition(!latestHasPreparation)
        playback.load(source: source, requestID: latest)
        try await until { !playback.isLoading }

        // Failed preparation falls back to normal resolution without a UI error.
        playback.prefetch(track(7)) { throw CancellationError() }
        let failedPreparation = playback.beginLoading(track: track(7), autoplay: false)
        let failedHasPreparation = await playback.loadPrefetched(requestID: failedPreparation)
        precondition(!failedHasPreparation)
        precondition(playback.isLoading && playback.errorMessage == nil)
        playback.load(source: source, requestID: failedPreparation)
        try await until { !playback.isLoading }

        // A standby player cannot start itself when the current track ends.
        let countBeforeEnd = preparedPlayers.count
        playback.prefetch(track(8)) { source }
        try await until { preparedPlayers.count == countBeforeEnd + 1 }
        let standbyAtEnd = preparedPlayers.last!
        didEnd = false
        playback.togglePlayPause()
        try await until { didEnd }
        precondition(playback.currentTrack == track(7))
        precondition(standbyAtEnd.rate == 0)

        // Sign-out invalidates an outstanding source and clears saved metadata.
        let pending = playback.beginLoading(track: track(2))
        playback.clearSession()
        playback.load(source: source, requestID: pending)
        playback.failLoading(requestID: pending, message: "Late failure")
        precondition(playback.currentTrack == nil && playback.player.currentItem == nil)
        precondition(!playback.isLoading && !playback.isPlaybackActive)
        precondition(playback.savedSession == nil && playback.errorMessage == nil)
        precondition(standbyAtEnd.currentItem == nil)

        // A late background response cannot create a player after sign-out.
        releaseResolution = nil
        playback.prefetch(track(9)) {
            await withCheckedContinuation { releaseResolution = $0 }
            return source
        }
        try await until { releaseResolution != nil }
        let countBeforeSignOut = preparedPlayers.count
        let signingOut = playback.beginLoading(track: track(9))
        let signedOutLoad = Task { await playback.loadPrefetched(requestID: signingOut) }
        await Task.yield()
        playback.clearSession()
        releaseResolution?.resume()
        let ignoredSignOut = await signedOutLoad.value
        precondition(ignoredSignOut && preparedPlayers.count == countBeforeSignOut)
        precondition(playback.currentTrack == nil)
        print("Playback tests passed")
    }

    @MainActor
    private static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Timed out waiting for local playback")
    }

    private static func writeSilence(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
