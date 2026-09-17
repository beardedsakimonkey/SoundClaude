import Foundation

@main
struct RecentSearchTests {
    static func main() {
        let suite = "RecentSearchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentSearchStore(defaults: defaults)
        let user = SoundCloudUser(
            urn: "soundcloud:users:1", username: "Test", avatarURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/test")!
        )
        let otherUser = SoundCloudUser(
            urn: nil, username: "Other", avatarURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/other")!
        )
        precondition(store.restore(for: user).isEmpty)
        precondition(store.record(" \n ", for: user).isEmpty)
        precondition(store.record("  Ambient 🌊 \n", for: user) == ["Ambient 🌊"])
        store.record("Jazz", for: user)
        precondition(store.record("ambient 🌊", for: user) == ["ambient 🌊", "Jazz"])
        let reopened = RecentSearchStore(defaults: UserDefaults(suiteName: suite)!)
        precondition(reopened.restore(for: user) == ["ambient 🌊", "Jazz"])
        precondition(reopened.restore(for: otherUser).isEmpty)
        store.record("Other search", for: otherUser)
        for index in 0..<15 { store.record("Query \(index)", for: user) }
        precondition(store.restore(for: user) == (5..<15).reversed().map { "Query \($0)" })
        store.clear(for: user)
        precondition(reopened.restore(for: user).isEmpty)
        precondition(reopened.restore(for: otherUser) == ["Other search"])
        print("Recent search persistence, ordering, deduplication, limit, and account isolation tests passed")
    }
}
