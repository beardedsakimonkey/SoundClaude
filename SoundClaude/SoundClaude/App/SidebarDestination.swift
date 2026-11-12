import Foundation

enum SidebarDestination: Codable, Hashable, Identifiable {
    case search
    case feed
    case liked
    case history

    static let libraryDestinations: [Self] = [.feed, .search, .liked, .history]

    var id: String {
        switch self {
        case .search: "search"
        case .feed: "feed"
        case .liked: "liked"
        case .history: "history"
        }
    }

    var title: String {
        switch self {
        case .search:
            "Search"
        case .feed:
            "Feed"
        case .liked:
            "Likes"
        case .history:
            "History"
        }
    }

    var systemImage: String {
        switch self {
        case .search:
            "magnifyingglass"
        case .feed:
            "list.bullet.rectangle"
        case .liked:
            "heart"
        case .history:
            "clock.arrow.circlepath"
        }
    }
}

enum Route: Codable, Hashable {
    case search(String)
    case genre(String)
    case tag(String)
    case playlist(SoundCloudPlaylist)
    case station(String, seedTrack: SoundCloudTrack? = nil, seedArtistName: String? = nil)
    case track(SoundCloudTrack)
    case relatedTracks(SoundCloudTrack)
    case trackPlaylists(SoundCloudTrack)
    case artist(SoundCloudUser)
    case artistUsers(SoundCloudUser, ArtistUserList)
    case artistComments(SoundCloudUser)
}

/// One visit to a route. Going back returns to the visit's scroll position; visiting
/// the same route again starts a new one at the top.
struct NavigationEntry {
    let route: Route
    let scrollPosition = RememberedScrollPosition()
}

struct NavigationHistory {
    var path: [NavigationEntry] = []
    var forwardPath: [NavigationEntry] = []
}

enum SearchCategory: String, CaseIterable, Codable {
    case tracks = "Tracks"
    case playlists = "Playlists"
    case users = "Users"

    var systemImage: String {
        switch self {
        case .tracks: "music.note"
        case .playlists: "music.note.list"
        case .users: "person"
        }
    }
}

enum ArtistContentTab: String, CaseIterable, Identifiable, Codable {
    case tracks = "Tracks"
    case reposts = "Reposts"
    case playlists = "Playlists"
    case likes = "Likes"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .tracks: "music.note"
        case .reposts: "arrow.2.squarepath"
        case .playlists: "music.note.list"
        case .likes: "heart"
        }
    }
}

// Persist every tab's Back and Forward history. Scroll positions stay transient, so
// restored pages start at the top.
struct NavigationSelection: Codable, Equatable {
    struct History: Codable, Equatable {
        /// The most recent visits kept per stack, to bound what each navigation saves.
        static let limit = 50

        var path: [Route] = []
        var forwardPath: [Route] = []

        var routes: [Route] { path + forwardPath }
    }

    var destination: SidebarDestination
    var histories: [SidebarDestination.ID: History] = [:]
    /// Results tabs of the search pages in `histories`. Tracks, the default, is omitted.
    var searchCategories: [String: SearchCategory] = [:]
    /// Content tabs of the artist pages in `histories`, by artist permalink.
    var artistTabs: [SidebarDestination.ID: [URL: ArtistContentTab]] = [:]

    init(destination: SidebarDestination, histories: [SidebarDestination.ID: NavigationHistory] = [:]) {
        self.destination = destination
        self.histories = histories.compactMapValues { history in
            guard !history.path.isEmpty || !history.forwardPath.isEmpty else { return nil }
            // Both stacks end with the visits nearest the visible page.
            return History(
                path: history.path.suffix(History.limit).map(\.route),
                forwardPath: history.forwardPath.suffix(History.limit).map(\.route)
            )
        }
    }

    var navigationHistories: [SidebarDestination.ID: NavigationHistory] {
        histories.mapValues { history in
            NavigationHistory(
                path: history.path.map { NavigationEntry(route: $0) },
                forwardPath: history.forwardPath.map { NavigationEntry(route: $0) }
            )
        }
    }
}

struct SidebarSelectionStore {
    var defaults: UserDefaults = .standard

    func restore(for user: SoundCloudUser) -> SidebarDestination {
        restoreNavigation(for: user).destination
    }

    func restoreNavigation(for user: SoundCloudUser) -> NavigationSelection {
        guard let data = defaults.data(forKey: key(for: user)) else {
            return NavigationSelection(destination: .feed)
        }
        // Unreadable settings must not prevent startup.
        return (try? JSONDecoder().decode(NavigationSelection.self, from: data))
            ?? NavigationSelection(destination: .feed)
    }

    func save(_ destination: SidebarDestination, for user: SoundCloudUser) {
        save(NavigationSelection(destination: destination), for: user)
    }

    func save(_ selection: NavigationSelection, for user: SoundCloudUser) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: key(for: user))
    }

    private func key(for user: SoundCloudUser) -> String {
        "sidebar.selection.\(user.urn ?? user.permalinkURL.absoluteString)"
    }
}
