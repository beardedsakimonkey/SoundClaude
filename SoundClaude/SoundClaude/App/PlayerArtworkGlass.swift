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
    var specularStrength = 0.08
    var specularSoftness = 0.25
    // How dark the slab's side is shaded (0...1).
    var slabShade = 0.5
    // How brightly the slab's rounded corners catch the light as they turn through it.
    var slabGlint = 0.35
    // The rounded bevel that bends the print near the edge: its width and how far, in points,
    // it pulls the outermost pixels inward. Off except on detail artwork.
    var refractionWidth = 12.0
    var refractionStrength = 0.0
    // How far apart the color channels bend (0...1), fringing the edge like a prism.
    var dispersion = 0.6
    // How strongly a thin coating tints the reflections with a shifting hue (0...1).
    var iridescence = 0.0
    // A softbox reflected in the glass that slides across as the cover turns. Its position is
    // along the light direction in reflected-view space; negative values sit opposite the light.
    var sheenStrength = 0.0
    var sheenPosition = -0.34
}

extension PlayerArtworkGlassParameters {
    // Detail artwork defaults captured from the Tune Glass controls.
    static var detail: Self {
        var parameters = Self()
        parameters.lipPosition = 1.0
        parameters.lipWidth = 1.0
        parameters.reflectionStrength = 0.5
        parameters.refractionStrength = 3.5
        parameters.dispersion = 0.3
        parameters.iridescence = 0.35
        parameters.sheenStrength = 0.14
        return parameters
    }
}

private struct PlayerArtworkGlassParametersKey: EnvironmentKey {
    static let defaultValue = PlayerArtworkGlassParameters()
}

// A lean driven outside SwiftUI's animations, such as a pointer tilt. Only the glass reads it,
// so each change re-renders the highlight without rebuilding the artwork.
@Observable
final class PlayerArtworkGlassTilt {
    // Sideways components of the glass's normal; zero while it faces the viewer.
    // Positive x leans the trailing edge back, positive y the bottom edge.
    var normal = CGSize.zero
}

extension EnvironmentValues {
    // Animated sideways offset of the slab's back face, in points; set by PlayerArtworkGlassSlab.
    @Entry var playerArtworkGlassSlabShift: CGFloat = 0
    @Entry var playerArtworkGlassTilt: PlayerArtworkGlassTilt? = nil

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
    // The side continues the face's nearer edge colors, shaded toward the back.
    var slabThickness: CGFloat = 0
    // The face's size when the caller knows it. Prefer this in scrolling content.
    var size: CGSize? = nil
    var shadowRadius: CGFloat = 6
    var shadowOffsetY: CGFloat = 3

    var animatableData: Double {
        get { rotation }
        set { rotation = newValue }
    }

    // Room for the slab edge at turns up to about 36 degrees.
    static func slabPadding(thickness: CGFloat) -> CGFloat {
        thickness > 0 ? ceil(thickness * 0.75) : 0
    }

    // Offset of the slab's back face: the animated turn's sideways shift plus the pointer lean's.
    // A layer `thickness` behind the face projects shifted by thickness * tan(angle), toward
    // the side that comes forward.
    static func slabShift(turnShift: CGFloat, tilt: CGSize, thickness: CGFloat) -> CGSize {
        let padding = slabPadding(thickness: thickness)
        guard padding > 0 else { return .zero }
        let cosine = sqrt(max(1 - tilt.width * tilt.width - tilt.height * tilt.height, 0.01))
        let leanScale = -thickness / cosine
        return CGSize(
            width: min(max(turnShift + tilt.width * leanScale, -padding), padding),
            height: min(max(tilt.height * leanScale, -padding), padding)
        )
    }

    @Environment(\.playerArtworkGlassParameters) private var parameters
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.playerArtworkGlassSlabShift) private var turnShift
    @Environment(\.playerArtworkGlassTilt) private var tilt

    func body(content: Content) -> some View {
        let parameters = parameters
        let tilt = tilt?.normal ?? .zero
        let enablesGlass = parameters.isEnabled && !reduceTransparency
        let slabPadding = enablesGlass ? Self.slabPadding(thickness: slabThickness) : 0
        let slabShift = Self.slabShift(turnShift: turnShift, tilt: tilt, thickness: slabThickness)
        let rotationRadians = rotation * .pi / 180
        // A dark side reads heavy against a light background.
        let slabShade = parameters.slabShade * (colorScheme == .light ? 0.6 : 1.0)
        // The slab edge reads the face's nearest edge, pulled in from the corners.
        let slabReach = slabPadding > 0 ? slabPadding + cornerRadius + 4 : 0
        // The bevel reads the print up to half again its bend further in.
        let refractionBend = min(parameters.refractionStrength, parameters.refractionWidth * 0.3)
        let refractionReach = refractionBend > 0 ? ceil(refractionBend * 1.5) + 1 : 0
        let sampleReach = max(slabReach, refractionReach)
        let maxSampleOffset = CGSize(width: sampleReach, height: sampleReach)
        let cornerRadius = cornerRadius
        let displayScale = displayScale
        let shader = { @Sendable (faceSize: CGSize) in
            Self.shader(
                faceSize: faceSize, cornerRadius: cornerRadius, parameters: parameters,
                rotation: rotationRadians, tilt: tilt, slabPadding: slabPadding, slabShift: slabShift,
                slabShade: slabShade, displayScale: displayScale
            )
        }
        let composited = content
            .padding(slabPadding)
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
                                      height: geometry.size.height - slabPadding * 2)),
                        maxSampleOffset: maxSampleOffset,
                        isEnabled: enablesGlass
                    )
                }
            }
        }
        .padding(-slabPadding)
        .shadow(color: .black.opacity(0.14), radius: 1, x: 0, y: 1)
        .shadow(color: .black.opacity(0.16), radius: shadowRadius, x: 0, y: shadowOffsetY)
    }

    nonisolated private static func shader(
        faceSize: CGSize, cornerRadius: CGFloat, parameters: PlayerArtworkGlassParameters,
        rotation: Double, tilt: CGSize, slabPadding: CGFloat, slabShift: CGSize, slabShade: Double,
        displayScale: CGFloat
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
            .float(parameters.specularStrength),
            .float(parameters.specularSoftness),
            .float(rotation),
            .float2(tilt.width, tilt.height),
            .float2(slabPadding, slabPadding),
            .float2(slabShift.width, slabShift.height),
            .float(slabShade),
            .float(parameters.slabGlint),
            .float(displayScale),
            .float(parameters.refractionWidth),
            .float(parameters.refractionStrength),
            .float(parameters.dispersion),
            .float(parameters.iridescence),
            .float(parameters.sheenStrength),
            .float(parameters.sheenPosition)
        )
    }
}

/// Zooms square artwork within its glass while hovered, as on the track grid tiles.
struct ArtworkHoverZoom: ViewModifier {
    let isHovering: Bool
    let cornerRadius: CGFloat
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovering && !reduceMotion ? 1.08 : 1)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .modifier(PlayerArtworkGlass(
                cornerRadius: cornerRadius,
                size: CGSize(width: size, height: size)
            ))
            .animation(
                reduceMotion ? nil : isHovering
                    ? .spring(response: 0.35, dampingFraction: 0.75)
                    : .spring(duration: 0.34, bounce: 0),
                value: isHovering
            )
    }
}
