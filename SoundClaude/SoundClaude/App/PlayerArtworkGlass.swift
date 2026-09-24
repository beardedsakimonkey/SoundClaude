import SwiftUI

// Defaults match the original shader. Overrides are scoped to the preview artwork.
struct PlayerArtworkGlassParameters {
    var isEnabled = true
    var rimWidth = 8.0
    var refraction = 4.2
    var dispersion = 0.45
    var lightAngle = -123.0238675558
    var edgeDarkening = 0.16
    var lipPosition = 1.1
    var lipWidth = 0.85
    var reflectionStrength = 1.0
    var causticStrength = 0.15
    var sweepStrength = 0.065
    var sweepWidth = 0.19
    var sweepPosition = 0.24
}

private struct PlayerArtworkGlassParametersKey: EnvironmentKey {
    static let defaultValue = PlayerArtworkGlassParameters()
}

extension EnvironmentValues {
    var playerArtworkGlassParameters: PlayerArtworkGlassParameters {
        get { self[PlayerArtworkGlassParametersKey.self] }
        set { self[PlayerArtworkGlassParametersKey.self] = newValue }
    }
}

struct PlayerArtworkGlass: ViewModifier {
    let cornerRadius: CGFloat
    let isHovering: Bool

    @Environment(\.playerArtworkGlassParameters) private var parameters
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let parameters = parameters
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let enablesRefraction = parameters.isEnabled && !reduceTransparency
        let sampleOffset = ceil(parameters.refraction + parameters.dispersion) + 1

        content
            .compositingGroup()
            .visualEffect { content, geometry in
                content.layerEffect(
                    ShaderLibrary.playerArtworkGlass(
                        .float2(geometry.size),
                        .float(cornerRadius),
                        .float(parameters.rimWidth),
                        .float(parameters.refraction),
                        .float(parameters.dispersion),
                        .float(parameters.lightAngle * .pi / 180),
                        .float(parameters.edgeDarkening),
                        .float(parameters.lipPosition),
                        .float(parameters.lipWidth),
                        .float(parameters.reflectionStrength),
                        .float(parameters.causticStrength),
                        .float(parameters.sweepStrength),
                        .float(parameters.sweepWidth),
                        .float(parameters.sweepPosition)
                    ),
                    // Include the largest color-channel bend plus filtering headroom.
                    maxSampleOffset: CGSize(width: sampleOffset, height: sampleOffset),
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
            .shadow(color: .black.opacity(0.24), radius: 4, x: 0, y: 4)
    }
}
