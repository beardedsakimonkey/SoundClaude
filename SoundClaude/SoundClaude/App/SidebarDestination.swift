import Foundation

enum SidebarDestination: Codable, Hashable, Identifiable {
    case feed
    case liked
    case history

    static let libraryDestinations: [Self] = [.feed, .liked, .history]

    var id: String {
        switch self {
        case .feed: "feed"
        case .liked: "liked"
        case .history: "history"
        }
    }

    var title: String {
        switch self {
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
