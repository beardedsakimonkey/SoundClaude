import Foundation

enum SidebarDestination: Hashable, Identifiable {
    case feed
    case liked
    case history
    case playlist(SoundCloudPlaylist)

    static let libraryDestinations: [Self] = [.feed, .liked, .history]

    var id: Self { self }

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
