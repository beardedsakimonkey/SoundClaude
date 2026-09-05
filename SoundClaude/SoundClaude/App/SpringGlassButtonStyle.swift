import SwiftUI

@available(macOS 26.0, *)
struct SpringGlassButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.glass(.clear))
            .modifier(GlassPressEffect())
    }
}

private struct GlassPressEffect: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @GestureState private var isPressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && isEnabled && !reduceMotion ? 0.92 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.65),
                value: isPressed && isEnabled
            )
            // Observe the press while the native button handles activation.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, pressed, _ in
                        pressed = true
                    },
                isEnabled: isEnabled
            )
    }
}
