import Foundation

@main
struct SidebarSelectionTests {
    static func main() throws {
        let suite = "SidebarSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SidebarSelectionStore(defaults: defaults)
        let user = SoundCloudUser(
            urn: "soundcloud:users:1", username: "Test", avatarURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/test")!
        )
        let otherUser = SoundCloudUser(
            urn: "soundcloud:users:2", username: "Other", avatarURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/other")!
        )
        precondition(store.restore(for: user) == .liked)
        for destination in SidebarDestination.libraryDestinations {
            store.save(destination, for: user)
            let reopened = SidebarSelectionStore(defaults: UserDefaults(suiteName: suite)!)
            precondition(reopened.restore(for: user) == destination)
            precondition(reopened.restore(for: otherUser) == .liked)
        }

        func playlist(title: String) -> SoundCloudPlaylist {
            SoundCloudPlaylist(
                urn: "soundcloud:playlists:123", title: title, owner: user,
                artworkURL: nil, permalinkURL: user.permalinkURL,
                description: nil, trackCount: 5, durationMilliseconds: nil,
                isPrivate: true
            )
        }
        let original = playlist(title: "Saved playlist")
        store.save(.playlist(original), for: user)
        let reopened = SidebarSelectionStore(defaults: UserDefaults(suiteName: suite)!)
        guard case let .playlist(restored) = reopened.restore(for: user) else {
            fatalError("Expected the saved playlist before the library loads")
        }
        precondition(restored == original)
        let refreshed = SidebarDestination.playlist(playlist(title: "Renamed playlist"))
        precondition(Set([SidebarDestination.playlist(restored)]).contains(refreshed))

        // Invalid settings must not prevent startup.
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("sidebar.selection.") {
            defaults.set(Data("invalid".utf8), forKey: key)
        }
        precondition(store.restore(for: user) == .liked)
        print("Sidebar selection tests passed")
    }
}
