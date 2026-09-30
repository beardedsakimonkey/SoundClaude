import Foundation

@main
struct HistoryTests {
    static func main() throws {
        let suite = "HistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HistoryStore(defaults: defaults)
        let user = SoundCloudUser(
            urn: "user:1", username: "Test", avatarURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/test")!
        )
        let other = SoundCloudUser(
            urn: nil, username: "Other", avatarURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/other")!
        )
        func track(_ id: Int, title: String? = nil) -> SoundCloudTrack {
            SoundCloudTrack(
                urn: "track:\(id)", title: title ?? "Track \(id)", artist: user,
                artworkURL: nil, waveformURL: nil,
                permalinkURL: URL(string: "https://soundcloud.com/test/\(id)")!,
                durationMilliseconds: 2000, access: .playable, secretToken: nil
            )
        }
        precondition(store.restore(for: user).isEmpty)
        store.record(track(1), for: user)
        store.record(track(2), for: user)
        let updated = track(1, title: "Updated title")
        precondition(store.record(updated, for: user) == [updated, track(2)])
        let reopened = HistoryStore(defaults: UserDefaults(suiteName: suite)!)
        precondition(reopened.restore(for: user) == [updated, track(2)])
        precondition(reopened.restore(for: other).isEmpty)
        store.record(track(3), for: other)
        precondition(store.restore(for: user) == [updated, track(2)])
        precondition(reopened.restore(for: other) == [track(3)])

        let tracks = reopened.restore(for: user)
        let queue = TrackQueue(source: .history, tracks: tracks)
        precondition(!queue.needsNextPage(after: tracks.last?.urn))
        precondition(queue.relativeTrack(to: tracks.first?.urn, offset: 1) == tracks.last)
        let restored = try JSONDecoder().decode(TrackQueue.self, from: JSONEncoder().encode(queue))
        precondition(restored.source == .history && restored.tracks == tracks)

        for id in 0...HistoryStore.limit { store.record(track(id), for: user) }
        precondition(store.restore(for: user).map(\.urn) == (1...HistoryStore.limit).reversed().map { "track:\($0)" })
        precondition(store.restore(for: other) == [track(3)])
        defaults.set(Data("invalid".utf8), forKey: "history.tracks.user:1")
        precondition(store.restore(for: user).isEmpty)
        precondition(store.record(track(4), for: user) == [track(4)])
        print("Local history persistence, ordering, deduplication, account isolation, limit, recovery, and queue checks passed")
    }
}
