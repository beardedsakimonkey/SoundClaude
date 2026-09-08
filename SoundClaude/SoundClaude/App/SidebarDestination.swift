import Foundation

enum SidebarDestination: Codable, Hashable, Identifiable {
    case feed
    case liked
    case history
    case playlist(SoundCloudPlaylist)

    static let libraryDestinations: [Self] = [.feed, .liked, .history]

    var id: String {
        switch self {
        case .feed: "feed"
        case .liked: "liked"
        case .history: "history"
        case let .playlist(playlist): "playlist:\(playlist.urn)"
        }
    }

    // Keep the restored row selected when playlist metadata changes on refresh.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var title: String {
        switch self {
        case .feed:
            "Feed"
        case .liked:
            "Liked"
        case .history:
            "History"
        case let .playlist(playlist):
            playlist.title
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
        case .playlist:
            "music.note.list"
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
