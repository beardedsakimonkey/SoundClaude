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

// Persist only the visible page. All other tab, Back, and Forward history is transient.
struct NavigationSelection: Codable, Equatable {
    var destination: SidebarDestination
    var route: Route? = nil
    /// The visible search page's results tab.
    var searchCategory: SearchCategory? = nil
    /// The visible artist page's content tab.
    var artistTab: ArtistContentTab? = nil

    var navigationHistories: [SidebarDestination.ID: NavigationHistory] {
        guard let route else { return [:] }
        return [destination.id: NavigationHistory(path: [NavigationEntry(route: route)])]
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
        let decoder = JSONDecoder()
        if let selection = try? decoder.decode(NavigationSelection.self, from: data) {
            return selection
        }
        // Keep the selected tab from versions that saved only the tab.
        let destination = (try? decoder.decode(SidebarDestination.self, from: data)) ?? .feed
        return NavigationSelection(destination: destination)
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
