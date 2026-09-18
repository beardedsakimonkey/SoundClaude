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
        let historyStore = NavigationHistoryStore(defaults: defaults)
        precondition(historyStore.restore(for: user).isEmpty)
        let track = SoundCloudTrack(
            urn: "soundcloud:tracks:1", title: "Track", artist: user,
            artworkURL: nil, waveformURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/test/track")!,
            durationMilliseconds: 1000, access: .playable, secretToken: nil
        )
        let playlist = SoundCloudPlaylist(
            urn: "soundcloud:playlists:1", title: "Playlist", owner: user,
            artworkURL: nil, permalinkURL: URL(string: "https://soundcloud.com/test/sets/playlist")!,
            description: nil, trackCount: 1, durationMilliseconds: 1000, isPrivate: false
        )
        let routes: [NavigationRoute] = [
            .search("a query"), .genre("Electronic"), .track(track), .playlist(playlist),
            .station("soundcloud:system-playlists:1"),
            .station("soundcloud:system-playlists:2", seedTrackURN: track.urn),
            .artist(user), .artistUsers(user, .followers), .artistUsers(user, .following)
        ]
        var histories = [String: NavigationHistory]()
        for destination in SidebarDestination.libraryDestinations {
            histories[destination.id] = NavigationHistory(
                path: routes, forwardPath: Array(routes.reversed())
            )
        }
        historyStore.save(histories, for: user)
        let restoredStore = NavigationHistoryStore(defaults: UserDefaults(suiteName: suite)!)
        precondition(restoredStore.restore(for: user) == histories)
        precondition(restoredStore.restore(for: otherUser).isEmpty)

        // Popping a restored page retains the next Forward destination after reopening.
        let last = histories["liked"]!.path.removeLast()
        histories["liked"]!.forwardPath.append(last)
        histories["feed"] = NavigationHistory()
        restoredStore.save(histories, for: user)
        precondition(historyStore.restore(for: user) == histories)
        precondition(historyStore.restore(for: user)["liked"]?.forwardPath.last == last)

        // Users without a URN use their profile URL, just like sidebar selection.
        let legacyUser = SoundCloudUser(
            urn: nil, username: "Legacy", avatarURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/legacy")!
        )
        historyStore.save(histories, for: legacyUser)
        precondition(restoredStore.restore(for: legacyUser) == histories)

        // Corrupt data or an unsupported route must not prevent startup.
        for data in [Data("invalid".utf8), Data(#"{"liked":{"path":[{"unknown":{}}],"forwardPath":[]}}"#.utf8)] {
            defaults.set(data, forKey: "navigation.histories.\(user.urn!)")
            precondition(restoredStore.restore(for: user).isEmpty)
            precondition(restoredStore.restore(for: legacyUser) == histories)
        }
        print("Sidebar selection and navigation history tests passed")
    }
}
