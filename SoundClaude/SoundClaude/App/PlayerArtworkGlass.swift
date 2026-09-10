import SwiftUI

struct PlayerArtworkGlass: ViewModifier {
    let cornerRadius: CGFloat
    let isHovering: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            // A lower rim gives the cover a visible glass thickness.
            .background {
                shape
                    .fill(LinearGradient(
                        colors: [Color(white: 0.75), Color(white: 0.22), Color(white: 0.48)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay {
                        shape.strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                    }
                    .offset(y: 2.5)
            }
            .overlay {
                ZStack {
                    // Opposing light and dark bevels make the surface look rounded.
                    shape.strokeBorder(LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.7), location: 0),
                            .init(color: .white.opacity(0.22), location: 0.35),
                            .init(color: .black.opacity(0.25), location: 0.7),
                            .init(color: .white.opacity(0.4), location: 1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ), lineWidth: 2.5)

                    shape.inset(by: 2.5)
                        .strokeBorder(LinearGradient(
                            colors: [.black.opacity(0.2), .clear, .white.opacity(0.3)],
                            startPoint: .top,
                            endPoint: .bottom
                        ), lineWidth: 0.75)

                    shape.strokeBorder(LinearGradient(
                        colors: [.white.opacity(0.85), .white.opacity(0.1), .white.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ), lineWidth: 0.5)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 2)
            .shadow(color: .black.opacity(isHovering ? 0.28 : 0.2), radius: 4, x: 0, y: 4)
    }
}
