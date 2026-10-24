import SwiftUI

struct DetailNavigationAnimation: ViewModifier {
    let trackURN: String?
    let isCollection: Bool
    let isVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wasVisible = true

    init(trackURN: String?, isCollection: Bool, bounds: CGRect, in geometry: GeometryProxy) {
        self.trackURN = trackURN
        self.isCollection = isCollection
        // Include the toolbar and footer insets, which content scrolls behind.
        let insets = geometry.safeAreaInsets
        let viewport = CGRect(
            x: 0, y: -insets.top,
            width: geometry.size.width, height: geometry.size.height + insets.top + insets.bottom
        )
        isVisible = bounds.intersects(viewport)
    }

    func body(content: Content) -> some View {
        content
            // Track changes, scrolling, and resizing stay immediate.
            .animation(nil, value: trackURN)
            // Only the move between track and collection layouts uses the spring.
            // Skip it when either slot is scrolled out of view, so controls don't fly in from the edge.
            .animation(
                reduceMotion || !(wasVisible && isVisible) ? nil : .spring(response: 0.42, dampingFraction: 0.9),
                value: isCollection
            )
            // Runs after the update that compares layouts, so that update still sees the old slot.
            .onChange(of: isVisible, initial: true) { wasVisible = isVisible }
    }
}

// Reset the entrance only when navigation also changes the displayed track.
// Playback changes within a collection keep the controls mounted.
struct DetailControlLifetime: ViewModifier {
    let routeID: AnyHashable
    let trackURN: String?
    @State private var generation = 0

    private struct Destination: Equatable {
        let routeID: AnyHashable
        let trackURN: String?
    }

    func body(content: Content) -> some View {
        content
            .id(generation)
            .transition(.identity)
            .onChange(of: Destination(routeID: routeID, trackURN: trackURN)) { old, new in
                if old.routeID != new.routeID && old.trackURN != new.trackURN {
                    generation += 1
                }
            }
    }
}
