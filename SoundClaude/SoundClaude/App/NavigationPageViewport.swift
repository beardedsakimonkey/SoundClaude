import SwiftUI

/// History belongs to the caller. Only the current route and an optional retained root stay mounted.
struct CurrentNavigationPage<Route: Hashable, Root: View, Destination: View>: View {
    let route: Route?
    var retainsRoot = false
    @ViewBuilder let root: () -> Root
    @ViewBuilder let destination: (Route) -> Destination

    var body: some View {
        if retainsRoot {
            ZStack {
                root()
                    .opacity(route == nil ? 1 : 0)
                    .allowsHitTesting(route == nil)
                    .accessibilityHidden(route != nil)
                if let route {
                    destination(route).id(route)
                }
            }
        } else if let route {
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

/// Mount each top-level page on first visit and retain it across sidebar selections.
struct RetainedRootPages<Selection: Hashable, Content: View>: View {
    let selections: [Selection]
    let selection: Selection
    let isActive: Bool
    @ViewBuilder let content: (Selection, Bool) -> Content

    @State private var visited: Set<Selection> = []

    var body: some View {
        ZStack {
            ForEach(selections, id: \.self) { candidate in
                if candidate == selection || visited.contains(candidate) {
                    let active = isActive && candidate == selection
                    content(candidate, active)
                        .opacity(active ? 1 : 0)
                        .allowsHitTesting(active)
                        .disabled(!active)
                        .accessibilityHidden(!active)
                }
            }
        }
        .onAppear { visited.insert(selection) }
        .onChange(of: selection) { old, new in
            visited.formUnion([old, new])
        }
    }
}
