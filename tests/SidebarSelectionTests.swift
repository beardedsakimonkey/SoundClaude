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
        precondition(store.restore(for: user) == .feed)
        for destination in SidebarDestination.libraryDestinations {
            store.save(destination, for: user)
            let reopened = SidebarSelectionStore(defaults: UserDefaults(suiteName: suite)!)
            precondition(reopened.restore(for: user) == destination)
            precondition(reopened.restore(for: otherUser) == .feed)
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
            .artist(user), .artistUsers(user, .followers), .artistUsers(user, .following),
            .artistComments(user)
        ]
        func history(_ path: [Route], forward: [Route] = []) -> NavigationHistory {
            NavigationHistory(
                path: path.map { NavigationEntry(route: $0) },
                forwardPath: forward.map { NavigationEntry(route: $0) }
            )
        }
        for destination in SidebarDestination.libraryDestinations {
            for route in routes {
                store.save(
                    NavigationSelection(destination: destination, histories: [destination.id: history([route])]),
                    for: user
                )
                let reopened = SidebarSelectionStore(defaults: UserDefaults(suiteName: suite)!)
                let selection = reopened.restoreNavigation(for: user)
                precondition(selection.destination == destination)
                precondition(selection.navigationHistories.count == 1)
                precondition(selection.navigationHistories[destination.id]?.path.map(\.route) == [route])
                precondition(selection.navigationHistories[destination.id]?.forwardPath.isEmpty == true)
                precondition(reopened.restoreNavigation(for: otherUser).navigationHistories.isEmpty)
            }
        }

        // Every tab's Back and Forward history survives a relaunch, with its tab choices.
        var saved = NavigationSelection(destination: .liked, histories: [
            SidebarDestination.liked.id: history(Array(routes.prefix(6)), forward: Array(routes.suffix(5))),
            SidebarDestination.search.id: history([.search("query"), .artist(user)]),
            SidebarDestination.feed.id: history([], forward: [.track(track)]),
            // A tab at its root has nothing to save.
            SidebarDestination.history.id: history([])
        ])
        saved.searchCategories["query"] = .users
        saved.artistTabs[SidebarDestination.search.id] = [user.permalinkURL: .likes]
        store.save(saved, for: user)
        let restored = SidebarSelectionStore(defaults: UserDefaults(suiteName: suite)!).restoreNavigation(for: user)
        precondition(restored == saved)
        let histories = restored.navigationHistories
        precondition(histories.count == 3)
        precondition(histories[SidebarDestination.liked.id]?.path.map(\.route) == Array(routes.prefix(6)))
        precondition(histories[SidebarDestination.liked.id]?.forwardPath.map(\.route) == Array(routes.suffix(5)))
        precondition(histories[SidebarDestination.search.id]?.path.map(\.route) == [.search("query"), .artist(user)])
        precondition(histories[SidebarDestination.feed.id]?.path.isEmpty == true)
        precondition(histories[SidebarDestination.feed.id]?.forwardPath.map(\.route) == [.track(track)])

        // Long histories keep the visits nearest the visible page.
        let limit = NavigationSelection.History.limit
        let visits: [Route] = (0..<(limit + 10)).map { .search("query \($0)") }
        let capped = NavigationSelection(
            destination: .feed, histories: [SidebarDestination.feed.id: history(visits, forward: visits)]
        ).histories[SidebarDestination.feed.id]!
        precondition(capped.path == Array(visits.suffix(limit)))
        precondition(capped.forwardPath == Array(visits.suffix(limit)))

        // Returning to a root clears the saved detail, including after switching tabs.
        store.save(NavigationSelection(destination: .history), for: user)
        precondition(store.restoreNavigation(for: user) == NavigationSelection(destination: .history))
        precondition(store.restoreNavigation(for: user).navigationHistories.isEmpty)

        // Invalid settings must not prevent startup.
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("sidebar.selection.") {
            defaults.set(Data("invalid".utf8), forKey: key)
        }
        precondition(store.restore(for: user) == .feed)
        print("Sidebar selection tests passed")
    }
}
