import Foundation

enum SidebarDestination: String, CaseIterable, Hashable, Identifiable {
    case home
    case liked

    var id: Self { self }

    var title: String {
        switch self {
        case .home:
            "Home"
        case .liked:
            "Liked"
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            "house"
        case .liked:
            "heart"
        }
    }
}
