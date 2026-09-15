import SwiftUI

struct PlayerArtworkGlass: ViewModifier {
    let cornerRadius: CGFloat
    let isHovering: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let enablesRefraction = !reduceTransparency

        content
            .compositingGroup()
            .visualEffect { content, geometry in
                content.layerEffect(
                    ShaderLibrary.playerArtworkGlass(
                        .float2(geometry.size),
                        .float(cornerRadius)
                    ),
                    // The shader bends samples inward by at most 4.65 points.
                    maxSampleOffset: CGSize(width: 6, height: 6),
                    isEnabled: enablesRefraction
                )
            }
            .overlay {
                shape.strokeBorder(LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.8), location: 0),
                        .init(color: .white.opacity(0.18), location: 0.3),
                        .init(color: .white.opacity(0.05), location: 0.55),
                        .init(color: .white.opacity(0.5), location: 1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ), lineWidth: 0.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .shadow(color: .black.opacity(0.20), radius: 1, x: 0, y: 1)
            .shadow(color: .black.opacity(isHovering ? 0.30 : 0.24), radius: 4, x: 0, y: 4)
    }
}
