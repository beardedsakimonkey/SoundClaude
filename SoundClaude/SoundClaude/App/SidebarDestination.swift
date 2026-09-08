import Foundation

enum SidebarDestination: Hashable, Identifiable {
    case feed
    case liked
    case playlist(SoundCloudPlaylist)

    static let libraryDestinations: [Self] = [.feed, .liked]

    var id: Self { self }

    var title: String {
        switch self {
        case .feed:
            "Feed"
        case .liked:
            "Liked"
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
        case .playlist:
            "music.note.list"
        }
    }
}
