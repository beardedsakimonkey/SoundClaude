import Foundation

struct HistoryStore {
    var defaults: UserDefaults = .standard
    static let limit = 500

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
