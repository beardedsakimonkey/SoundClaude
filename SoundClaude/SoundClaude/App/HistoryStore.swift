import Foundation

struct HistoryStore {
    var defaults: UserDefaults = .standard
    static let limit = 500
    private static let recordingQueue = DispatchQueue(
        label: "com.tim.soundclaude.native.history", qos: .utility
    )

    // Serialize the complete read/modify/write operation so rapid track starts
    // are retained in order. Capture the account when playback starts.
    func recordDeferred(
        _ track: SoundCloudTrack,
        for user: SoundCloudUser,
        delay: TimeInterval = 1,
        completion: @escaping @Sendable ([SoundCloudTrack]) -> Void
    ) {
        Self.recordingQueue.asyncAfter(deadline: .now() + delay) {
            completion(record(track, for: user))
        }
    }

    func restore(for user: SoundCloudUser) -> [SoundCloudTrack] {
        guard let data = defaults.data(forKey: key(for: user)),
              let tracks = try? JSONDecoder().decode([SoundCloudTrack].self, from: data)
        else { return [] }
        return Array(tracks.prefix(Self.limit))
    }

    @discardableResult
    func record(_ track: SoundCloudTrack, for user: SoundCloudUser) -> [SoundCloudTrack] {
        var tracks = restore(for: user)
        tracks.removeAll { $0.urn == track.urn }
        tracks.insert(track, at: 0)
        tracks = Array(tracks.prefix(Self.limit))
        if let data = try? JSONEncoder().encode(tracks) {
            defaults.set(data, forKey: key(for: user))
        }
        return tracks
    }

    private func key(for user: SoundCloudUser) -> String {
        "history.tracks.\(user.urn ?? user.permalinkURL.absoluteString)"
    }
}
