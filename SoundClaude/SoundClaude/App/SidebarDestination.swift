import Foundation

enum SidebarDestination: Codable, Hashable, Identifiable {
    case search
    case feed
    case liked
    case history

    static let libraryDestinations: [Self] = [.search, .feed, .liked, .history]

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

struct SidebarSelectionStore {
    var defaults: UserDefaults = .standard

    func restore(for user: SoundCloudUser) -> SidebarDestination {
        guard let data = defaults.data(forKey: key(for: user)),
              let destination = try? JSONDecoder().decode(SidebarDestination.self, from: data)
        else { return .liked }
        return destination
    }

    func save(_ destination: SidebarDestination, for user: SoundCloudUser) {
        guard let data = try? JSONEncoder().encode(destination) else { return }
        defaults.set(data, forKey: key(for: user))
    }

    private func key(for user: SoundCloudUser) -> String {
        "sidebar.selection.\(user.urn ?? user.permalinkURL.absoluteString)"
    }
}

// Store both directions for every sidebar section so switching sections after
// relaunch retains the same Back and Forward behavior.
struct NavigationHistory: Codable, Equatable {
    var path: [NavigationRoute] = []
    var forwardPath: [NavigationRoute] = []
}

enum NavigationRoute: Codable, Hashable {
    case search(String)
    case genre(String)
    case playlist(SoundCloudPlaylist)
    case station(String, seedTrackURN: String? = nil)
    case track(SoundCloudTrack)
    case artist(SoundCloudUser)
    case artistUsers(SoundCloudUser, ArtistUserList)
}

struct NavigationHistoryStore {
    var defaults: UserDefaults = .standard

    func restore(for user: SoundCloudUser) -> [SidebarDestination.ID: NavigationHistory] {
        guard let data = defaults.data(forKey: key(for: user)),
              let histories = try? JSONDecoder().decode(
                [SidebarDestination.ID: NavigationHistory].self, from: data
              )
        else { return [:] }
        return histories
    }

    func save(_ histories: [SidebarDestination.ID: NavigationHistory], for user: SoundCloudUser) {
        guard let data = try? JSONEncoder().encode(histories) else { return }
        defaults.set(data, forKey: key(for: user))
    }

    private func key(for user: SoundCloudUser) -> String {
        "navigation.histories.\(user.urn ?? user.permalinkURL.absoluteString)"
    }
}
