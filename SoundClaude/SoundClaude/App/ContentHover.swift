import SwiftUI

private struct ContentHoverEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var contentHoverEnabled: Bool {
        get { self[ContentHoverEnabledKey.self] }
        set { self[ContentHoverEnabledKey.self] = newValue }
    }
}

extension View {
    /// Tracks hover while respecting overlays that suppress background hover effects.
    func onContentHover(perform action: @escaping (Bool) -> Void) -> some View {
        modifier(ContentHoverModifier(action: action))
    }
}

private struct ContentHoverModifier: ViewModifier {
    let action: (Bool) -> Void
    @Environment(\.contentHoverEnabled) private var isEnabled
    @State private var isPointerInside = false

    func body(content: Content) -> some View {
        content
            .onHover { isPointerInside = $0 }
            // Keep tracking while suppressed so hover is restored when the overlay closes.
            .onChange(of: isPointerInside && isEnabled, initial: true) { _, isHovering in
                action(isHovering)
            }
            .onDisappear {
                isPointerInside = false
                action(false)
            }
    }
}
