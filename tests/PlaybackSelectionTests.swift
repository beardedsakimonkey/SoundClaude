import Foundation
import Observation
import os

@main
struct PlaybackSelectionTests {
    @MainActor
    static func main() {
        let suite = "SoundClaude.PlaybackSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let user = SoundCloudUser(
            urn: "user:1", username: "Test", avatarURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/test")!
        )
        func track(_ id: Int, durationMilliseconds: Int = 2000) -> SoundCloudTrack {
            SoundCloudTrack(
                urn: "track:\(id)", title: "Track \(id)", artist: user,
                artworkURL: nil, waveformURL: nil,
                permalinkURL: URL(string: "https://soundcloud.com/test/\(id)")!,
                durationMilliseconds: durationMilliseconds, access: .playable, secretToken: nil
            )
        }
        // Track views observe their own selection, and only read transport
        // state while selected. Switching tracks must leave other views alone.
        do {
            let controller = PlaybackController(defaults: defaults)
            let changes = (1...3).map { _ in OSAllocatedUnfairLock(initialState: 0) }
            func observeTrack(_ id: Int) {
                let counter = changes[id - 1]
                withObservationTracking {
                    if controller[isCurrentTrack: track(id).urn] {
                        _ = controller.isPlaybackActive
                        _ = controller.isPlaying
                        _ = controller.isLoading
                    }
                } onChange: {
                    counter.withLock { $0 += 1 }
                }
            }
            for id in 1...3 { observeTrack(id) }
            controller.beginLoading(track: track(1))
            precondition(changes.map { $0.withLock { $0 } } == [1, 0, 0])
            precondition(controller[isCurrentTrack: track(1).urn])
            observeTrack(1)
            controller.beginLoading(track: track(2))
            precondition(changes.map { $0.withLock { $0 } } == [2, 1, 0])
            precondition(!controller[isCurrentTrack: track(1).urn])
            precondition(controller[isCurrentTrack: track(2).urn])
            observeTrack(1)
            observeTrack(2)
            controller.pause()
            precondition(changes.map { $0.withLock { $0 } } == [2, 2, 0])

            // Reloading the same URN does not change selection.
            let selectionChanges = OSAllocatedUnfairLock(initialState: 0)
            withObservationTracking {
                _ = controller[isCurrentTrack: track(2).urn]
            } onChange: {
                selectionChanges.withLock { $0 += 1 }
            }
            controller.beginLoading(track: track(2))
            precondition(selectionChanges.withLock { $0 } == 0)
            let restored = PlaybackController(defaults: defaults)
            precondition(restored[isCurrentTrack: track(2).urn])
            precondition(!restored[isCurrentTrack: track(1).urn])
            controller.resetSession(preservingPlayback: false)
            precondition(selectionChanges.withLock { $0 } == 1)
            precondition(!controller[isCurrentTrack: track(2).urn])
            precondition(changes[0].withLock { $0 } == 2)
            precondition(changes[2].withLock { $0 } == 0)
        }
        print("Playback selection observation tests passed")
    }
}
