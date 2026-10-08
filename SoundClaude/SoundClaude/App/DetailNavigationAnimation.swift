import SwiftUI

struct DetailNavigationAnimation: ViewModifier {
    let trackURN: String?
    let isCollection: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            // Track changes, scrolling, and resizing stay immediate.
            .animation(nil, value: trackURN)
            // Only the move between track and collection layouts uses the spring.
            .animation(
                reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9),
                value: isCollection
            )
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
