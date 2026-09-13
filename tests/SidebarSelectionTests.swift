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

        // A playlist saved by an older version must fall back to a library root.
        let key = "sidebar.selection.\(user.urn!)"
        defaults.set(Data(#"{"playlist":{"_0":{"urn":"soundcloud:playlists:123","title":"Saved playlist"}}}"#.utf8), forKey: key)
        let reopened = SidebarSelectionStore(defaults: UserDefaults(suiteName: suite)!)
        precondition(reopened.restore(for: user) == .liked)

        // Invalid settings must not prevent startup.
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("sidebar.selection.") {
            defaults.set(Data("invalid".utf8), forKey: key)
        }
        precondition(store.restore(for: user) == .liked)
        print("Sidebar selection tests passed")
    }
}
