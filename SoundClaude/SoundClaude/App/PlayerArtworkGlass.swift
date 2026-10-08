import SwiftUI

// Defaults match the original shader. Overrides are scoped to the preview artwork.
struct PlayerArtworkGlassParameters {
    var isEnabled = true
    var rimWidth = 8.0
    var lightAngle = -123.0238675558
    var edgeDarkening = 0.16
    var lipPosition = 1.1
    var lipWidth = 0.85
    var reflectionStrength = 1.0
    var causticStrength = 0.15
    var sweepStrength = 0.065
    var sweepWidth = 0.19
    var sweepPosition = 0.24
    var hoverSweepBoost = 0.0
    // Base darkness, then the fraction of remaining light removed toward the back.
    var slabDarkness = 0.32
    var slabDepthShading = (0.54 - 0.32) / (1.0 - 0.32)
    // Scales the hairline rim stroke drawn over the face.
    var rimStrokeOpacity = 1.0
}

extension PlayerArtworkGlassParameters {
    // Turned detail covers: a broader, dimmer lip and stroke so the lit corner doesn't
    // read as a hard line against the slab edge.
    static var detail: Self {
        var parameters = Self()
        parameters.hoverSweepBoost = 0.6
        parameters.lipPosition = 1.8
        parameters.lipWidth = 1.8
        parameters.reflectionStrength = 0.55
        parameters.rimStrokeOpacity = 0.44
        return parameters
    }
}

private struct PlayerArtworkGlassParametersKey: EnvironmentKey {
    static let defaultValue = PlayerArtworkGlassParameters()
}

extension EnvironmentValues {
    // Animated sideways offset of the slab's back face, in points; set by PlayerArtworkGlassSlab.
    @Entry var playerArtworkGlassSlabShift: CGFloat = 0

    var playerArtworkGlassParameters: PlayerArtworkGlassParameters {
        get { self[PlayerArtworkGlassParametersKey.self] }
        set { self[PlayerArtworkGlassParametersKey.self] = newValue }
    }
}

/// Animates the slab edge separately from the glass's hover sheen, which runs on its own spring.
struct PlayerArtworkGlassSlab: ViewModifier, Animatable {
    var shift: CGFloat

    var animatableData: CGFloat {
        get { shift }
        set { shift = newValue }
    }

    func body(content: Content) -> some View {
        content.environment(\.playerArtworkGlassSlabShift, shift)
    }
}

struct PlayerArtworkGlass: ViewModifier, Animatable {
    let cornerRadius: CGFloat
    // Moves the face reflection as the cover lifts toward the light. Zero keeps it fixed.
    var hoverSweepTravel = 0.0
    // Nonzero pads the shader layer so it can draw the slab's side past the face.
    // Needs `artworkOverscan` to supply the artwork the side shows.
    var slabThickness: CGFloat = 0
    // How far the content draws past its frame on every side, unclipped. The glass masks it
    // to the face, and the slab's side reveals the overscan.
    var artworkOverscan: CGFloat = 0
    private var hoverProgress: Double

    var animatableData: Double {
        get { hoverProgress }
        set { hoverProgress = newValue }
    }

    init(
        cornerRadius: CGFloat,
        isHovering: Bool,
        hoverSweepTravel: Double = 0,
        slabThickness: CGFloat = 0,
        artworkOverscan: CGFloat = 0
    ) {
        self.cornerRadius = cornerRadius
        self.hoverSweepTravel = hoverSweepTravel
        self.slabThickness = slabThickness
        self.artworkOverscan = artworkOverscan
        hoverProgress = isHovering ? 1 : 0
    }

    // Room for the slab edge at turns up to about 36 degrees, limited to the artwork available.
    static func slabPadding(thickness: CGFloat, overscan: CGFloat) -> CGFloat {
        thickness > 0 ? min(ceil(thickness * 0.75), overscan) : 0
    }

    @Environment(\.playerArtworkGlassParameters) private var parameters
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.playerArtworkGlassSlabShift) private var slabShift

    func body(content: Content) -> some View {
        let parameters = parameters
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let enablesGlass = parameters.isEnabled && !reduceTransparency
        let slabPadding = enablesGlass ? Self.slabPadding(thickness: slabThickness, overscan: artworkOverscan) : 0
        let slabShift = min(max(slabShift, -slabPadding), slabPadding)
        let sweepPosition = parameters.sweepPosition + hoverSweepTravel * hoverProgress
        let sweepStrength = parameters.sweepStrength * (1 + parameters.hoverSweepBoost * hoverProgress)

        content
            .padding(.horizontal, slabPadding)
            // Trim overscan to the slab's room, or to the face when the shader can't mask it.
            .clipShape(enablesGlass ? AnyShape(Rectangle()) : AnyShape(shape), isActive: artworkOverscan > 0)
            .compositingGroup()
            .visualEffect { content, geometry in
                content.layerEffect(
                    ShaderLibrary.playerArtworkGlass(
                        .float2(geometry.size.width - slabPadding * 2, geometry.size.height),
                        .float(cornerRadius),
                        .float(parameters.rimWidth),
                        .float(parameters.lightAngle * .pi / 180),
                        .float(parameters.edgeDarkening),
                        .float(parameters.lipPosition),
                        .float(parameters.lipWidth),
                        .float(parameters.reflectionStrength),
                        .float(parameters.causticStrength),
                        .float(sweepStrength),
                        .float(parameters.sweepWidth),
                        .float(sweepPosition),
                        .float2(slabPadding, 0),
                        .float(artworkOverscan > 0 ? 1 : 0),
                        .float(slabShift),
                        .float2(parameters.slabDarkness, parameters.slabDepthShading)
                    ),
                    maxSampleOffset: .zero,
                    isEnabled: enablesGlass
                )
            }
            .padding(.horizontal, -slabPadding)
            .overlay {
                shape.strokeBorder(LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.8 * parameters.rimStrokeOpacity), location: 0),
                        .init(color: .white.opacity(0.18 * parameters.rimStrokeOpacity), location: 0.3),
                        .init(color: .white.opacity(0.05 * parameters.rimStrokeOpacity), location: 0.55),
                        .init(color: .white.opacity(0.5 * parameters.rimStrokeOpacity), location: 1)
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

private extension View {
    @ViewBuilder
    func clipShape(_ shape: AnyShape, isActive: Bool) -> some View {
        if isActive {
            clipShape(shape)
        } else {
            self
        }
    }
}
