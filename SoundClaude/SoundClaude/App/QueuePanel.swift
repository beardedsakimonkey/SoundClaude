import Observation
import SwiftUI

/// Glass over a fill that tones down what shows through. The queue and the search
/// suggestions share it.
struct QueuePanelGlass: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        Group {
            if #available(macOS 26.0, *) {
                // Glass applied to the content itself swallows the rows' clicks and drop targets.
                content.background { Color.clear.glassEffect(.regular, in: shape) }
            } else {
                content.background(.regularMaterial, in: shape)
                    .overlay {
                        shape.strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
            }
        }
        .background(
            (colorScheme == .dark ? Color.black : Color.white)
                .opacity(colorScheme == .dark ? 0.4 : 0.6),
            in: shape
        )
    }
}

// Keep visibility reads, including binding creation, outside the navigation body.
@Observable
final class QueuePresentation {
    var isVisible = false
}

struct QueuePresentationReader<Content: View>: View {
    @Bindable var presentation: QueuePresentation
    @ViewBuilder let content: (Binding<Bool>) -> Content

    var body: some View {
        content($presentation.isVisible)
    }
}
