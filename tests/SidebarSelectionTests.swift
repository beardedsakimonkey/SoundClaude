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

        let track = SoundCloudTrack(
            urn: "soundcloud:tracks:1", title: "Track", artist: user,
            artworkURL: nil, waveformURL: nil, permalinkURL: user.permalinkURL,
            durationMilliseconds: 1000, access: .playable, secretToken: nil
        )
        let playlist = SoundCloudPlaylist.systemPlaylist(urn: "soundcloud:system-playlists:1", title: "Mix")
        let routes: [Route] = [
            .search("query"), .genre("Ambient"), .tag("live"), .track(track),
            .playlist(playlist), .station("station", seedTrack: track),
            .station("artist-station", seedArtistName: user.username),
            .artist(user), .artistUsers(user, .followers), .artistUsers(user, .following)
        ]
        for destination in SidebarDestination.libraryDestinations {
            for route in routes {
                let history = NavigationHistory(path: [.search("earlier"), route], forwardPath: [.tag("later")])
                store.save(NavigationSelection(destination: destination, route: history.path.last), for: user)
                let reopened = SidebarSelectionStore(defaults: UserDefaults(suiteName: suite)!)
                let selection = reopened.restoreNavigation(for: user)
                precondition(selection.destination == destination)
                precondition(selection.navigationHistories.count == 1)
                precondition(selection.navigationHistories[destination.id]?.path == [route])
                precondition(selection.navigationHistories[destination.id]?.forwardPath.isEmpty == true)
                precondition(reopened.restoreNavigation(for: otherUser).navigationHistories.isEmpty)
            }
        }

        // Returning to a root clears the saved detail, including after switching tabs.
        store.save(NavigationSelection(destination: .history), for: user)
        precondition(store.restoreNavigation(for: user) == NavigationSelection(destination: .history))
        precondition(store.restoreNavigation(for: user).navigationHistories.isEmpty)

        // Tab-only settings from previous versions remain valid.
        for destination in SidebarDestination.libraryDestinations {
            defaults.set(try JSONEncoder().encode(destination), forKey: "sidebar.selection.\(user.urn!)")
            precondition(store.restoreNavigation(for: user) == NavigationSelection(destination: destination))
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
