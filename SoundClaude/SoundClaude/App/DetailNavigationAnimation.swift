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
