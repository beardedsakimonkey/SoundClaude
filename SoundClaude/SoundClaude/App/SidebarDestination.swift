import Foundation

enum SidebarDestination: Hashable, Identifiable {
    case home
    case liked
    case playlist(SoundCloudPlaylist)

    static let libraryDestinations: [Self] = [.home, .liked]

    var id: Self { self }

    var title: String {
        switch self {
        case .home:
            "Home"
        case .liked:
            "Liked"
        case let .playlist(playlist):
            playlist.title
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            "house"
        case .liked:
            "heart"
        case .playlist:
            "music.note.list"
        }
    }
}
