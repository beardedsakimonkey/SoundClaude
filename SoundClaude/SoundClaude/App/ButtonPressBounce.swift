import SwiftUI

extension View {
    func pressBounce(_ isPressed: Bool) -> some View {
        modifier(ButtonPressBounce(isPressed: isPressed))
    }
}

private struct ButtonPressBounce: ViewModifier {
    let isPressed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let isPressed = isPressed && isEnabled && !reduceMotion
        content
            .scaleEffect(isPressed ? 0.86 : 1)
            .animation(
                isPressed
                    ? .spring(response: 0.38, dampingFraction: 0.6)
                    : .spring(response: 0.38, dampingFraction: 0.42),
                value: isPressed
            )
    }
}
