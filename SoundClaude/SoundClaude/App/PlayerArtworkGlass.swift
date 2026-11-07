import SwiftUI

// Shared glass defaults. Detail artwork uses its own tuned values below.
struct PlayerArtworkGlassParameters {
    var isEnabled = true
    var rimWidth = 8.0
    var lightAngle = -123.0238675558
    var edgeDarkening = 0.16
    var lipPosition = 1.1
    var lipWidth = 0.85
    var reflectionStrength = 0.75
    var causticStrength = 0.15
    var specularStrength = 0.08
    var specularSoftness = 0.25
    // Base darkness, then the fraction of remaining light removed toward the back.
    var slabDarkness = 0.32
    var slabDepthShading = (0.54 - 0.32) / (1.0 - 0.32)
}

extension PlayerArtworkGlassParameters {
    // Detail artwork defaults captured from the Tune Glass controls.
    static var detail: Self {
        var parameters = Self()
        parameters.slabDarkness = 0.23
        parameters.slabDepthShading = 0.36
        parameters.lipPosition = 1.0
        parameters.lipWidth = 1.0
        parameters.reflectionStrength = 0.5
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

/// Animates the projected slab edge alongside the artwork rotation.
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
    // Y rotation in degrees, animated with the same spring as the artwork.
    var rotation = 0.0
    // Nonzero pads the shader layer so it can draw the slab's side past the face.
    // The side shows the face's nearer edge flipped horizontally.
    var slabThickness: CGFloat = 0
    // The face's size when the caller knows it. Prefer this in scrolling content.
    var size: CGSize? = nil

    var animatableData: Double {
        get { rotation }
        set { rotation = newValue }
    }

    // Room for the slab edge at turns up to about 36 degrees.
    static func slabPadding(thickness: CGFloat) -> CGFloat {
        thickness > 0 ? ceil(thickness * 0.75) : 0
    }

    @Environment(\.playerArtworkGlassParameters) private var parameters
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.playerArtworkGlassSlabShift) private var slabShift

    func body(content: Content) -> some View {
        let parameters = parameters
        let enablesGlass = parameters.isEnabled && !reduceTransparency
        let slabPadding = enablesGlass ? Self.slabPadding(thickness: slabThickness) : 0
        let slabShift = min(max(slabShift, -slabPadding), slabPadding)
        let rotationRadians = rotation * .pi / 180
        let slabDarknessScale = colorScheme == .light ? 0.0 : 1.0
        // The slab edge reads the face across the edge, pulled in from the corners.
        let maxSampleOffset = slabPadding > 0
            ? CGSize(width: slabPadding * 2 + cornerRadius, height: cornerRadius)
            : .zero
        let cornerRadius = cornerRadius
        let shader = { @Sendable (faceSize: CGSize) in
            Self.shader(
                faceSize: faceSize, cornerRadius: cornerRadius, parameters: parameters,
                rotation: rotationRadians, slabPadding: slabPadding, slabShift: slabShift,
                slabDarknessScale: slabDarknessScale
            )
        }
        let composited = content
            .padding(.horizontal, slabPadding)
            .compositingGroup()

        Group {
            if let size {
                // visualEffect re-runs whenever the view moves, which re-renders
                // the shader on every scroll frame. A known size avoids that.
                composited.layerEffect(
                    shader(size), maxSampleOffset: maxSampleOffset, isEnabled: enablesGlass
                )
            } else {
                composited.visualEffect { content, geometry in
                    content.layerEffect(
                        shader(CGSize(width: geometry.size.width - slabPadding * 2,
                                      height: geometry.size.height)),
                        maxSampleOffset: maxSampleOffset,
                        isEnabled: enablesGlass
                    )
                }
            }
        }
        .padding(.horizontal, -slabPadding)
        .shadow(color: .black.opacity(0.14), radius: 1, x: 0, y: 1)
        .shadow(color: .black.opacity(0.16), radius: 6, x: 0, y: 3)
    }

    nonisolated private static func shader(
        faceSize: CGSize, cornerRadius: CGFloat, parameters: PlayerArtworkGlassParameters,
        rotation: Double, slabPadding: CGFloat, slabShift: CGFloat, slabDarknessScale: Double
    ) -> Shader {
        ShaderLibrary.playerArtworkGlass(
            .float2(faceSize.width, faceSize.height),
            .float(cornerRadius),
            .float(parameters.rimWidth),
            .float(parameters.lightAngle * .pi / 180),
            .float(parameters.edgeDarkening),
            .float(parameters.lipPosition),
            .float(parameters.lipWidth),
            .float(parameters.reflectionStrength),
            .float(parameters.causticStrength),
            .float(parameters.specularStrength),
            .float(parameters.specularSoftness),
            .float(rotation),
            .float2(slabPadding, 0),
            .float(slabShift),
            .float2(parameters.slabDarkness * slabDarknessScale, parameters.slabDepthShading)
        )
    }
}
