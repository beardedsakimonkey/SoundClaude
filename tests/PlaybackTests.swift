import AVFoundation
import Foundation

// Hold stream resolution between beginLoading and load. A local silent file
// tests AVPlayer readiness without credentials, network access, or audio output.
@main
struct PlaybackTests {
    @MainActor
    static func main() async throws {
        let suite = "SoundClaude.PlaybackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let playback = PlaybackController(defaults: defaults)
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

        // Sign-out invalidates an outstanding source and clears saved metadata.
        let pending = playback.beginLoading(track: track(2))
        playback.clearSession()
        playback.load(source: source, requestID: pending)
        playback.failLoading(requestID: pending, message: "Late failure")
        precondition(playback.currentTrack == nil && playback.player.currentItem == nil)
        precondition(!playback.isLoading && !playback.isPlaybackActive)
        precondition(playback.savedSession == nil && playback.errorMessage == nil)
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
