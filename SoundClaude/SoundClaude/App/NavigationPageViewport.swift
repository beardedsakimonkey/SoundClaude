import SwiftUI

/// History belongs to the caller. Only the current route has a live page subtree.
struct CurrentNavigationPage<Route: Hashable, Root: View, Destination: View>: View {
    let route: Route?
    @ViewBuilder let root: () -> Root
    @ViewBuilder let destination: (Route) -> Destination

    var body: some View {
        if let route {
            destination(route).id(route)
        } else {
            root()
        }
    }
}

/// Pages fill the detail column; their contents must not set the stack's ideal size.
/// A flexible frame still measures its child. GeometryReader answers the stack's
/// sizing queries without traversing the page's artwork, text, and lists.
struct NavigationPageViewport: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
