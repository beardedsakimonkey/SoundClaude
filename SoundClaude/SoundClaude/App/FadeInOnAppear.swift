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
