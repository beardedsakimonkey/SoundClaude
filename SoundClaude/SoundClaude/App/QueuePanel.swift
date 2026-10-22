import SwiftUI

struct QueuePanel<Content: View>: View {
    let bounds: CGSize
    let isVisible: Bool
    let hoverSuppression: ContentHoverSuppression
    // Constructed by the parent, so geometry changes reuse the same content.
    let content: Content

    var body: some View {
        let margin: CGFloat = 8
        let width = min(440, max(0, bounds.width - margin * 2))
        let height = min(520, max(0, bounds.height - margin * 2))
        let x = max(0, bounds.width - margin - width - 16)
        let y = max(0, bounds.height - margin - height + 8)
        ZStack(alignment: .topLeading) {
            if isVisible {
                content
                    .frame(width: width, height: height)
                    .modifier(QueuePanelGlass())
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .onHover { hoverSuppression.isSuppressed = $0 }
                    .onDisappear { hoverSuppression.isSuppressed = false }
                    .offset(x: x, y: y)
                    .transition(.offset(y: 24).combined(with: .opacity))
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
    }
}

private struct QueuePanelGlass: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        Group {
            if #available(macOS 26.0, *) {
                // Glass applied to the content itself swallows the rows' drop targets.
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
