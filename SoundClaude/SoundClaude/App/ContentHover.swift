import Observation
import SwiftUI

// Share overlay hover without making the screen that owns it observe changes.
@Observable
final class ContentHoverSuppression {
    var isSuppressed = false
}

private struct ContentHoverSuppressionKey: EnvironmentKey {
    static let defaultValue: ContentHoverSuppression? = nil
}

private struct ContentHoverEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var contentHoverSuppression: ContentHoverSuppression? {
        get { self[ContentHoverSuppressionKey.self] }
        set { self[ContentHoverSuppressionKey.self] = newValue }
    }

    var contentHoverEnabled: Bool {
        get { self[ContentHoverEnabledKey.self] }
        set { self[ContentHoverEnabledKey.self] = newValue }
    }
}

extension View {
    /// Tracks hover while respecting overlays that suppress background hover effects.
    func onContentHover(in path: Path? = nil, perform action: @escaping (Bool) -> Void) -> some View {
        modifier(ContentHoverModifier(path: path, action: action))
    }
}

private struct ContentHoverModifier: ViewModifier {
    let path: Path?
    let action: (Bool) -> Void
    @Environment(\.contentHoverEnabled) private var isEnabled
    @Environment(\.contentHoverSuppression) private var suppression
    @State private var isPointerInside = false

    func body(content: Content) -> some View {
        hoverTracking(content)
            // Keep tracking while suppressed so hover is restored when the overlay closes.
            // Only hovered content observes suppression changes.
            .onChange(of: isPointerInside && isEnabled && suppression?.isSuppressed != true, initial: true) { _, isHovering in
                action(isHovering)
            }
            .onDisappear {
                isPointerInside = false
                action(false)
            }
    }

    @ViewBuilder
    private func hoverTracking(_ content: Content) -> some View {
        if let path {
            content.onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    isPointerInside = path.contains(location)
                case .ended:
                    isPointerInside = false
                }
            }
        } else {
            content.onHover { isPointerInside = $0 }
        }
    }
}
