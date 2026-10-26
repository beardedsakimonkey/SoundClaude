import AppKit
import SwiftUI

// TrackQueue pagination errors are outside this storage regression.
enum SoundCloudError: Error { case invalidData }

private final class Evaluations {
    var count = 0
}

private struct SettingsView: View {
    @AppStorage("playlistTrackLayout") private var layout = "list"
    let evaluations: Evaluations

    var body: some View {
        evaluations.count += 1
        return Text(layout)
    }
}

@main
struct PlaybackSessionStorageTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let settingsName = "SoundClaude.SettingsTest.\(UUID().uuidString)"
        let sessionName = "SoundClaude.SessionTest.\(UUID().uuidString)"
        let volumeName = "SoundClaude.VolumeTest.\(UUID().uuidString)"
        let volumes = UserDefaults(suiteName: volumeName)!
        let settings = UserDefaults(suiteName: settingsName)!
        let sessions = UserDefaults(suiteName: sessionName)!
        defer {
            volumes.removePersistentDomain(forName: volumeName)
            settings.removePersistentDomain(forName: settingsName)
            sessions.removePersistentDomain(forName: sessionName)
        }
        let track = SoundCloudTrack(
            urn: "track:1", title: "Test",
            artist: SoundCloudUser(
                urn: "user:1", username: "Test", avatarURL: nil,
                permalinkURL: URL(string: "https://soundcloud.com/test")!
            ),
            artworkURL: nil, waveformURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/test/1")!,
            durationMilliseconds: 60_000, access: .playable, secretToken: nil
        )
        settings.set(Float(0.4), forKey: "playback.volume")
        settings.set(true, forKey: "playback.isMuted")
        let playback = PlaybackController(
            defaults: settings, sessionDefaults: sessions, volumeDefaults: volumes)
        precondition(playback.volume == 0.4 && playback.isMuted)
        precondition(settings.persistentDomain(forName: settingsName)?["playback.volume"] == nil)
        precondition(settings.persistentDomain(forName: settingsName)?["playback.isMuted"] == nil)
        playback.beginLoading(track: track)
        playback.seek(to: 12)
        playback.saveSession()
        precondition(playback.currentTrack?.urn == track.urn)
        precondition(playback.savedSession?.position == 12)
        precondition(settings.data(forKey: "playback.session") == nil)

        let evaluations = Evaluations()
        let host = NSHostingView(rootView:
            SettingsView(evaluations: evaluations).defaultAppStorage(settings))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        let initialCount = evaluations.count
        precondition(initialCount > 0)
        for position in [13.0, 18.0, 23.0] {
            playback.seek(to: position)
            playback.saveSession()
            settle()
            precondition(evaluations.count == initialCount,
                         "Session saves must not reevaluate views that observe UI settings")
        }
        for volume: Float in [0.2, 0.7, 1] {
            playback.volume = volume
            playback.isMuted = false
            settle()
            precondition(evaluations.count == initialCount,
                         "Volume changes must not reevaluate views that observe UI settings")
            precondition(playback.player.volume == volume)
        }
        playback.toggleMute()
        settle()
        precondition(evaluations.count == initialCount,
                     "Mute changes must not reevaluate views that observe UI settings")
        precondition(playback.player.isMuted)
        // Existing values in the separate store take precedence over legacy values.
        settings.set(Float(0.1), forKey: "playback.volume")
        let reopenedVolume = PlaybackController(
            defaults: settings, sessionDefaults: sessions, volumeDefaults: volumes)
        precondition(reopenedVolume.volume == 1 && reopenedVolume.isMuted)
        settle()
        let countAfterMigration = evaluations.count
        var queue = TrackQueue(source: .single, tracks: [track])
        let queueStore = TrackQueueStore(defaults: sessions)
        queueStore.save(queue)
        settle()
        precondition(evaluations.count == countAfterMigration,
                     "Queue saves must not reevaluate views that observe UI settings")
        queue.remove(track)
        queueStore.save(queue)
        settle()
        precondition(evaluations.count == countAfterMigration,
                     "Queue removal must not reevaluate views that observe UI settings")
        queueStore.clear()
        settle()
        precondition(evaluations.count == countAfterMigration,
                     "Queue clearing must not reevaluate views that observe UI settings")

        // Migrate existing queues, prefer an already migrated queue, and never resurrect a cleared queue.
        let oldQueue = TrackQueue(source: .single, tracks: [track])
        TrackQueueStore(defaults: settings).save(oldQueue)
        let migrated = TrackQueueStore(defaults: sessions, legacyDefaults: settings)
        precondition(migrated.restore(currentTrack: nil, shuffleEnabled: false).tracks == [track])
        precondition(settings.data(forKey: "playback.queue") == nil)
        migrated.save(queue)
        TrackQueueStore(defaults: settings).save(oldQueue)
        let reopened = TrackQueueStore(defaults: sessions, legacyDefaults: settings)
        precondition(reopened.restore(currentTrack: nil, shuffleEnabled: false).tracks.isEmpty)
        reopened.clear()
        let clearedQueue = TrackQueueStore(defaults: sessions, legacyDefaults: settings)
        precondition(clearedQueue.restore(currentTrack: nil, shuffleEnabled: false).tracks.isEmpty)

        // Settings changes must still reach the view.
        settle()
        let beforeSettingsChange = evaluations.count
        settings.set("grid", forKey: "playlistTrackLayout")
        settle()
        precondition(evaluations.count > beforeSettingsChange)
        let restored = PlaybackController(defaults: settings, sessionDefaults: sessions)
        precondition(restored.savedSession?.position == 23)
        restored.clearSession()
        let cleared = PlaybackController(defaults: settings, sessionDefaults: sessions)
        precondition(cleared.savedSession == nil, "Cleared sessions must not reappear")
        print("Playback session storage tests passed")
    }
}
