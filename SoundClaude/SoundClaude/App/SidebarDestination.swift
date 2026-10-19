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

enum Route: Codable, Hashable {
    case search(String)
    case genre(String)
    case tag(String)
    case playlist(SoundCloudPlaylist)
    case station(String, seedTrack: SoundCloudTrack? = nil, seedArtistName: String? = nil)
    case track(SoundCloudTrack)
    case artist(SoundCloudUser)
    case artistUsers(SoundCloudUser, ArtistUserList)
}

struct NavigationHistory {
    var path: [Route] = []
    var forwardPath: [Route] = []
}

// Persist only the visible page. All other tab, Back, and Forward history is transient.
struct NavigationSelection: Codable, Equatable {
    var destination: SidebarDestination
    var route: Route? = nil

    var navigationHistories: [SidebarDestination.ID: NavigationHistory] {
        guard let route else { return [:] }
        return [destination.id: NavigationHistory(path: [route])]
    }
}

struct SidebarSelectionStore {
    var defaults: UserDefaults = .standard

    func restore(for user: SoundCloudUser) -> SidebarDestination {
        restoreNavigation(for: user).destination
    }

    func restoreNavigation(for user: SoundCloudUser) -> NavigationSelection {
        guard let data = defaults.data(forKey: key(for: user)) else {
            return NavigationSelection(destination: .liked)
        }
        let decoder = JSONDecoder()
        if let selection = try? decoder.decode(NavigationSelection.self, from: data) {
            return selection
        }
        // Keep the selected tab from versions that saved only the tab.
        let destination = (try? decoder.decode(SidebarDestination.self, from: data)) ?? .liked
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
