import SwiftUI

struct FadeInOnAppear: ViewModifier {
    var isEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    func body(content: Content) -> some View {
        content
            .animation(!isEnabled || reduceMotion ? nil : .easeInOut(duration: 0.3)) { view in
                view.opacity(!isEnabled || reduceMotion || hasAppeared ? 1 : 0)
            }
            .onAppear {
                // Lazy rows can appear after the data insertion transaction has finished.
                hasAppeared = true
            }
    }
}

/// Fades in the lazy rows that mount before the first of them appears, together; rows that
/// mount later (scrolling, later pages) show at once. The list owns `hasRevealed` and resets
/// it to fade in a fresh set of rows.
struct FadeInUntilRevealed: ViewModifier {
    @Binding var hasRevealed: Bool
    var isEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .animation(!isEnabled || reduceMotion ? nil : .easeInOut(duration: 0.3)) { view in
                view.opacity(!isEnabled || reduceMotion || hasRevealed ? 1 : 0)
            }
            .onAppear {
                // Lazy rows appear after the data insertion transaction has finished.
                if isEnabled, !hasRevealed { hasRevealed = true }
            }
    }
}
