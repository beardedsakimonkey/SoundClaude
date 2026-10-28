import AppKit
import SwiftUI

struct TrackArtworkView: View {
    let artworkURL: URL?
    let loader: ArtworkLoader
    let size: CGFloat
    let rendition: ArtworkLoader.Rendition
    let shape: RoundedRectangle
    let showsBorder: Bool
    let animatesChanges: Bool
    let showsPlaceholderIcon: Bool

    @State private var image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        artworkURL: URL?,
        loader: ArtworkLoader,
        size: CGFloat,
        rendition: ArtworkLoader.Rendition = .source,
        shape: RoundedRectangle = RoundedRectangle(cornerRadius: 3),
        showsBorder: Bool = true,
        animatesChanges: Bool = false,
        showsPlaceholderIcon: Bool = true
    ) {
        self.artworkURL = artworkURL
        self.loader = loader
        self.size = size
        self.rendition = rendition
        self.shape = shape
        self.showsBorder = showsBorder
        self.animatesChanges = animatesChanges
        self.showsPlaceholderIcon = showsPlaceholderIcon
    }

    var body: some View {
        ZStack {
            shape
                .fill(.quaternary)
            if let image = image ?? artworkURL.flatMap({ loader.cachedImage(for: $0, rendition: rendition) }) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
                    .zIndex(1)
            } else if showsPlaceholderIcon {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay {
            if showsBorder {
                shape
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
        .task(id: artworkURL) {
            if let artworkURL, let cached = loader.cachedImage(for: artworkURL, rendition: rendition) {
                withAnimation(animatesChanges && !reduceMotion ? .easeInOut(duration: 0.3) : nil) {
                    image = cached
                }
                return
            }
            if !animatesChanges {
                image = nil
            }
            let nextImage: NSImage?
            if let artworkURL,
               let loaded = try? await loader.image(for: artworkURL, rendition: rendition) {
                nextImage = loaded
            } else {
                nextImage = nil
            }
            guard !Task.isCancelled else { return }
            withAnimation(animatesChanges && !reduceMotion ? .easeInOut(duration: 0.3) : nil) {
                image = nextImage
            }
        }
    }
}

struct DetailArtworkTrackAnimation: ViewModifier {
    let trackURN: String?
    @State private var previousTrackURN: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            // Loading the first track is not a track change.
            .animation(
                previousTrackURN != nil && trackURN != nil
                    ? .easeInOut(duration: reduceMotion ? 0.2 : 0.45) : nil,
                value: trackURN
            )
            .onChange(of: trackURN, initial: true) { _, newValue in
                previousTrackURN = newValue
            }
    }
}

struct DetailArtworkTransition: Transition {
    let playback: PlaybackController
    let reduceMotion: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        // Removed views retain their transition. Read the current direction from
        // playback here so their exit does not reuse the direction of their entrance.
        let distance: CGFloat = playback.trackChangeDirection == .forward ? 60 : -60
        let offset: CGFloat = switch phase {
        case .willAppear: distance
        case .identity: 0
        case .didDisappear: -distance
        }

        content.modifier(DetailArtworkSlide(
            offset: reduceMotion ? 0 : offset,
            opacity: phase.isIdentity ? 1 : 0
        ))
    }
}

private struct DetailArtworkSlide: ViewModifier, Animatable {
    var offset: CGFloat
    var opacity: Double

    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(offset, opacity) }
        set {
            offset = newValue.first
            opacity = newValue.second
        }
    }

    func body(content: Content) -> some View {
        // Pass the interpolated position to the entire cover on every frame.
        // Newly loaded images then receive the current position, not the target.
        content
            .offset(x: offset)
            .opacity(opacity)
    }
}

struct ArtworkButtonStyle<ArtworkShape: Shape>: ButtonStyle {
    let isHovering: Bool
    let shape: ArtworkShape

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .artworkExpandIndicator(isHovering: isHovering)
            .clipShape(shape)
    }
}

extension View {
    func artworkExpandIndicator(isHovering: Bool) -> some View {
        modifier(ArtworkExpandIndicator(isHovering: isHovering))
    }
}

private struct ArtworkExpandIndicator: ViewModifier {
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if isHovering {
                    Color.black.opacity(0.5)
                        .overlay {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 48, weight: .regular))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .transition(.opacity)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}

struct CachedFullSizeArtwork {
    let sourceURL: URL
    let data: Data
}

struct FullSizeArtworkView: View {
    let title: String
    let artworkURL: URL?
    let loader: ArtworkLoader

    @Environment(\.dismiss) private var dismiss
    @Binding private var cachedArtwork: CachedFullSizeArtwork?
    @State private var image: NSImage?
    @State private var isLoading: Bool
    @State private var errorMessage: String?

    init(
        title: String,
        artworkURL: URL?,
        loader: ArtworkLoader,
        cachedArtwork: Binding<CachedFullSizeArtwork?>
    ) {
        self.title = title
        self.artworkURL = artworkURL
        self.loader = loader
        _cachedArtwork = cachedArtwork

        let cachedImage = cachedArtwork.wrappedValue.flatMap { cached in
            cached.sourceURL == artworkURL ? NSImage(data: cached.data) : nil
        }
        _image = State(initialValue: cachedImage)
        _isLoading = State(initialValue: cachedImage == nil)
    }

    var body: some View {
        let displaySize = artworkDisplaySize

        ZStack(alignment: .topTrailing) {
            Group {
                Color.black

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .accessibilityLabel("Artwork for \(title)")
                } else if isLoading {
                    LoadingSpinner()
                        .accessibilityLabel("Loading artwork")
                        .tint(.white)
                        .foregroundStyle(.white)
                } else {
                    ContentUnavailableView {
                        Label(
                            "Could not load artwork",
                            systemImage: "photo.badge.exclamationmark"
                        )
                    } description: {
                        Text(errorMessage ?? "An unknown error occurred.")
                    } actions: {
                        Button("Try Again") {
                            Task { await load() }
                        }
                    }
                    .foregroundStyle(.white)
                }
            }
            .frame(width: displaySize.width, height: displaySize.height)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.65), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .contentHelp("Close")
            .accessibilityLabel("Close artwork")
            .padding(12)
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .dismissOnOutsideClick()
        .task(id: artworkURL) {
            guard image == nil else { return }
            await load()
        }
    }

    private var artworkDisplaySize: CGSize {
        guard let image,
              image.size.width > 0,
              image.size.height > 0 else {
            return CGSize(width: 480, height: 480)
        }

        let maximumDimension: CGFloat = 640
        let scale = maximumDimension
            / max(image.size.width, image.size.height)
        return CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
    }

    private func load() async {
        image = nil
        isLoading = true
        errorMessage = nil

        guard let artworkURL else {
            isLoading = false
            errorMessage = "This track does not have artwork."
            return
        }

        do {
            let data = try await loader.data(
                for: artworkURL,
                rendition: .original
            )
            guard let loadedImage = NSImage(data: data) else {
                throw ArtworkLoadError.invalidImage
            }
            cachedArtwork = CachedFullSizeArtwork(
                sourceURL: artworkURL,
                data: data
            )
            image = loadedImage
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private enum ArtworkLoadError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "The artwork data is not a valid image."
    }
}

struct TrackArtworkBackdropView: View {
    let artworkURL: URL?
    let loader: ArtworkLoader
    var fadesToBottom = true
    var animatesChanges = false
    var cachedImage: NSImage? = nil

    private let transitionDuration: Double = 0.8

    @State private var image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = cachedImage ?? image ?? artworkURL.flatMap({ loader.cachedImage(for: $0) }) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height
                        )
                        .scaleEffect(1.15)
                        .blur(radius: 36)
                        .saturation(1.15)
                        .opacity(colorScheme == .dark ? 0.38 : 0.25)
                        .mask {
                            if fadesToBottom {
                                LinearGradient(
                                    stops: [
                                        .init(color: .black, location: 0),
                                        .init(color: .black.opacity(0.75), location: 0.6),
                                        .init(color: .clear, location: 1)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            } else {
                                Rectangle()
                            }
                        }
                        .id(ObjectIdentifier(image))
                        .transition(.opacity)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: artworkURL) {
            guard cachedImage == nil else { return }
            if let artworkURL, let cached = loader.cachedImage(for: artworkURL) {
                withAnimation(animatesChanges && !reduceMotion ? .easeOut(duration: transitionDuration) : nil) {
                    image = cached
                }
                return
            }
            if !animatesChanges {
                image = nil
            }
            let nextImage: NSImage?
            if let artworkURL,
               let loaded = try? await loader.image(for: artworkURL) {
                nextImage = loaded
            } else {
                nextImage = nil
            }
            guard !Task.isCancelled else { return }
            withAnimation(animatesChanges && !reduceMotion ? .easeOut(duration: transitionDuration) : nil) {
                image = nextImage
            }
        }
    }
}

enum DetailArtworkMotion {
    static let hoverLift: CGFloat = 1
    static let hoverScale: CGFloat = 1.04

    static let hoverIn: Animation = .spring(response: 0.35, dampingFraction: 0.65)
    static let hoverOut: Animation = .spring(response: 0.35 * 1.5, dampingFraction: 0.75)

    static let rotationIn: Animation = .spring(response: 0.45, dampingFraction: 0.7)
    static let rotationOut: Animation = .spring(response: 0.9, dampingFraction: 0.7)
}

struct DetailArtworkTransform {
    var y = 24.0
    var perspective = 0.7
    // Where the right-edge fade begins across the artwork (0...1).
    var fadeStart = 0.35
    // Opacity left at the right edge at the full turn (0...1).
    var fadeEdgeOpacity = 0.5
    // Fade direction in degrees up from the right edge; 0 fades horizontally.
    var fadeAngle = 19.0
}

extension EnvironmentValues {
    @Entry var initialDetailArtworkRotation: Bool? = nil
    @Entry var detailArtworkHoverActive = false
    // Target Y rotation in degrees; the artwork's slab edge animates toward it alongside the turn.
    @Entry var detailArtworkYRotation = 0.0
    // The configured turn when the artwork rotates at all; sizes the slab's artwork overscan.
    @Entry var detailArtworkTurn = 0.0
}

/// Rotates the artwork and its reflection together, resetting Y rotation on hover or while viewing artwork.
struct DetailArtworkRotation: ViewModifier {
    var transform = DetailArtworkTransform()
    var isRotated = true
    var isShowingArtwork = false
    var flattensOnHover = true
    // When supplied, the image owns hover tracking instead of the larger header.
    var imageHover: Bool? = nil

    private let hoverInsets = EdgeInsets(top: 20, leading: 10, bottom: -10, trailing: 0)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    @Environment(\.initialDetailArtworkRotation) private var initialRotation
    @State private var hasAppeared = false

    #if DEBUG
    @AppStorage(DetailArtworkSlabTuning.turnKey) private var debugTurn = DetailArtworkTransform().y
    @AppStorage(DetailArtworkSlabTuning.fadeStartKey) private var debugFadeStart = DetailArtworkTransform().fadeStart
    @AppStorage(DetailArtworkSlabTuning.fadeEdgeOpacityKey) private var debugFadeEdgeOpacity =
        DetailArtworkTransform().fadeEdgeOpacity
    @AppStorage(DetailArtworkSlabTuning.fadeAngleKey) private var debugFadeAngle = DetailArtworkTransform().fadeAngle
    private var turn: Double { debugTurn }
    private var fadeStart: Double { debugFadeStart }
    private var fadeEdgeOpacity: Double { debugFadeEdgeOpacity }
    private var fadeAngle: Double { debugFadeAngle }
    #else
    private var turn: Double { transform.y }
    private var fadeStart: Double { transform.fadeStart }
    private var fadeEdgeOpacity: Double { transform.fadeEdgeOpacity }
    private var fadeAngle: Double { transform.fadeAngle }
    #endif

    private var displayedRotation: Bool {
        if !reduceMotion, !hasAppeared, let initialRotation { return initialRotation }
        return isRotated
    }

    private var activeHover: Bool { imageHover ?? isHovering }
    private var isRotationFlat: Bool { (flattensOnHover && activeHover) || isShowingArtwork }
    private var targetRotation: Double { displayedRotation && !isRotationFlat ? turn : 0 }

    func body(content: Content) -> some View {
        hoverTracking(content
            // Share one hover state with the image and its reflection.
            .environment(\.detailArtworkHoverActive, activeHover || isShowingArtwork)
            .environment(\.detailArtworkYRotation, targetRotation)
            // Reserve the full crop at both poses so rotation does not animate
            // image sizing, slab padding, or the reflection mask.
            .environment(\.detailArtworkTurn, turn)
            .animation(
                reduceMotion ? nil : (isRotationFlat
                    ? DetailArtworkMotion.rotationIn : DetailArtworkMotion.rotationOut)
            ) { artwork in
                rotated(artwork, perspective: displayedRotation ? transform.perspective : 0)
            }
            .onAppear { hasAppeared = true }
        )
    }

    @ViewBuilder
    private func hoverTracking<Artwork: View>(_ artwork: Artwork) -> some View {
        if imageHover != nil {
            artwork
        } else {
            artwork
                // Keep the adjusted hover bounds outside the transform.
                .padding(hoverInsets)
                .contentShape(Rectangle())
                .onContentHover { isHovering = $0 }
                // Preserve the artwork's original layout size.
                .padding(EdgeInsets(
                    top: -hoverInsets.top,
                    leading: -hoverInsets.leading,
                    bottom: -hoverInsets.bottom,
                    trailing: -hoverInsets.trailing
                ))
        }
    }

    // 0 when flat, 1 at the full configured turn.
    private var turnProgress: Double { turn == 0 ? 0 : min(abs(targetRotation / turn), 1) }

    // Fades the receding edge into the background as the artwork turns, angled toward the top right.
    private func trailingFade(progress: Double) -> some View {
        let edgeOpacity = 1 - (1 - fadeEdgeOpacity) * progress
        // Extend past the frame so the slab edge and shadows stay unclipped.
        let bleed: CGFloat = 60
        return GeometryReader { geometry in
            let size = geometry.size
            let angle = fadeAngle * .pi / 180
            let direction = CGVector(dx: cos(angle), dy: -sin(angle))
            // Span the gradient across the frame's extent along the fade direction.
            let halfExtent = (size.width * abs(direction.dx) + size.height * abs(direction.dy)) / 2
            let paddedSize = CGSize(width: size.width + bleed * 2, height: size.height + bleed * 2)
            let unitPoint = { (sign: CGFloat) in
                UnitPoint(
                    x: (bleed + size.width / 2 + sign * direction.dx * halfExtent) / paddedSize.width,
                    y: (bleed + size.height / 2 + sign * direction.dy * halfExtent) / paddedSize.height
                )
            }
            // The gradient's end colors extend into the bleed.
            LinearGradient(
                stops: [
                    .init(color: .black, location: fadeStart),
                    .init(color: .black.opacity(edgeOpacity), location: 1)
                ],
                startPoint: unitPoint(-1),
                endPoint: unitPoint(1)
            )
            .padding(-bleed)
        }
    }

    private func rotated<Artwork: View>(_ artwork: Artwork, perspective: Double) -> some View {
        artwork
            .mask { trailingFade(progress: turnProgress) }
            .rotation3DEffect(
                .degrees(targetRotation),
                axis: (x: 0, y: 1, z: 0),
                perspective: perspective
            )
    }
}

struct DetailArtworkView: View {
    enum HoverStyle {
        case lift, rotation
    }

    let artworkURL: URL?
    let title: String
    let loader: ArtworkLoader
    let size: CGFloat
    var animatesChanges = false
    var showsPlaceholderIcon = true
    var cornerRadius: CGFloat = 6
    var reflectionBlurRadius: CGFloat = 3
    // Depth of the glass slab, visible along the near edge while rotated.
    var slabThickness: CGFloat = 8
    var artworkLift: CGFloat = 0
    var hoverStyle: HoverStyle = .rotation
    var isShowingArtwork = false
    var onImageHover: ((Bool) -> Void)? = nil
    var track: SoundCloudTrack? = nil
    let likes: LikesController
    let onAddToQueue: (SoundCloudTrack) -> Void
    var onRemoveFromPlaylist: ((SoundCloudTrack) -> Void)? = nil
    var isUpdatingPlaylist = false
    let onShowArtwork: () -> Void

    private var reflectionHeight: CGFloat { size * 0.45 }
    private var displayedLift: CGFloat { reduceMotion ? 0 : artworkLift }
    // 0 at rest, 1 at a typical 8pt hover lift.
    private var liftProgress: CGFloat { min(displayedLift / 8, 1.5) }

    private enum ReflectionFade {
        // Opacity at the artwork's bottom edge (0...1).
        static let topOpacity: Double = 0.65
        // Distance down the reflection where it becomes invisible (0...1).
        static let fadeEnd: CGFloat = 0.85
        // Higher values fade faster near the top; 1 gives a linear fade.
        static let falloff: Double = 3.7

        static func stops(topOpacity: Double, fadeEnd: CGFloat, falloff: Double) -> [Gradient.Stop] {
            (0...32).map { step in
                let progress = Double(step) / 32
                return Gradient.Stop(
                    color: .black.opacity(topOpacity * pow(1 - progress, falloff)),
                    location: CGFloat(progress) * fadeEnd
                )
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.detailArtworkYRotation) private var rotation
    @Environment(\.detailArtworkTurn) private var turn
    @State private var likeErrorMessage: String?

    #if DEBUG
    @AppStorage(DetailArtworkSlabTuning.thicknessKey) private var debugSlabThickness = 8.0
    @AppStorage(DetailArtworkSlabTuning.darknessKey) private var debugSlabDarkness =
        PlayerArtworkGlassParameters.detail.slabDarkness
    @AppStorage(DetailArtworkSlabTuning.depthShadingKey) private var debugSlabDepthShading =
        PlayerArtworkGlassParameters.detail.slabDepthShading
    @AppStorage(DetailArtworkSlabTuning.lipPositionKey) private var debugLipPosition =
        PlayerArtworkGlassParameters.detail.lipPosition
    @AppStorage(DetailArtworkSlabTuning.lipWidthKey) private var debugLipWidth =
        PlayerArtworkGlassParameters.detail.lipWidth
    @AppStorage(DetailArtworkSlabTuning.lipStrengthKey) private var debugLipStrength =
        PlayerArtworkGlassParameters.detail.reflectionStrength
    @AppStorage(DetailArtworkSlabTuning.turnKey) private var debugTurn = DetailArtworkTransform().y
    @AppStorage(DetailArtworkSlabTuning.fadeStartKey) private var debugFadeStart = DetailArtworkTransform().fadeStart
    @AppStorage(DetailArtworkSlabTuning.fadeEdgeOpacityKey) private var debugFadeEdgeOpacity =
        DetailArtworkTransform().fadeEdgeOpacity
    @AppStorage(DetailArtworkSlabTuning.fadeAngleKey) private var debugFadeAngle = DetailArtworkTransform().fadeAngle
    @AppStorage("debug.specular.strength") private var debugSpecularStrength =
        PlayerArtworkGlassParameters.detail.specularStrength
    @AppStorage("debug.specular.softness") private var debugSpecularSoftness =
        PlayerArtworkGlassParameters.detail.specularSoftness
    @State private var isShowingSlabControls = false

    private var displayedSlabThickness: CGFloat { debugSlabThickness }
    private var glassParameters: PlayerArtworkGlassParameters {
        var parameters = PlayerArtworkGlassParameters.detail
        parameters.slabDarkness = debugSlabDarkness
        parameters.slabDepthShading = debugSlabDepthShading
        parameters.lipPosition = debugLipPosition
        parameters.lipWidth = debugLipWidth
        parameters.reflectionStrength = debugLipStrength
        parameters.specularStrength = debugSpecularStrength
        parameters.specularSoftness = debugSpecularSoftness
        return parameters
    }
    #else
    private var displayedSlabThickness: CGFloat { slabThickness }
    private var glassParameters: PlayerArtworkGlassParameters { .detail }
    #endif

    // Artwork drawn past the face on every side, just enough for the widest slab edge at the
    // configured turn. The face shows a zoomed crop and the edge shows the rest, so the image
    // runs continuously onto the edge.
    private var displayedOverscan: CGFloat {
        displayedSlabThickness * tan(abs(turn) * .pi / 180)
    }

    private var reflectionStops: [Gradient.Stop] {
        ReflectionFade.stops(
            topOpacity: ReflectionFade.topOpacity,
            fadeEnd: ReflectionFade.fadeEnd,
            falloff: ReflectionFade.falloff
        )
    }

    var body: some View {
        // Keep overscan fixed while the cover and glass slab rotate.
        artworkStack(overscan: displayedOverscan)
        #if DEBUG
        .popover(isPresented: $isShowingSlabControls, arrowEdge: .trailing) {
            slabControls
        }
        #endif
        .alert("Could not update like", isPresented: Binding(
            get: { likeErrorMessage != nil },
            set: { if !$0 { likeErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { likeErrorMessage = nil }
        } message: {
            Text(likeErrorMessage ?? "Please try again.")
        }
    }

    private func artworkStack(overscan: CGFloat) -> some View {
        VStack(spacing: 1) {
            draggableArtworkControl(overscan: overscan)
                .onContentHover { onImageHover?($0) }
                .contextMenu {
                    if let track {
                        TrackMenuItems(
                            track: track,
                            likes: likes,
                            likeErrorMessage: $likeErrorMessage,
                            onAddToQueue: onAddToQueue,
                            onRemoveFromPlaylist: onRemoveFromPlaylist,
                            isUpdatingPlaylist: isUpdatingPlaylist
                        )
                    }
                    #if DEBUG
                    Divider()
                    Button("Tune Glass…") { isShowingSlabControls = true }
                    #endif
                }
                .animation(
                    reduceMotion ? nil : (displayedLift > 0
                        ? DetailArtworkMotion.hoverIn : DetailArtworkMotion.hoverOut)
                ) { artwork in
                    artwork.shadow(
                        color: .black.opacity(0.22),
                        radius: 6 + 10 * liftProgress,
                        x: 0,
                        y: 4 + 10 * liftProgress
                    )
                }
                .offset(y: -displayedLift)
                .zIndex(1)

            artworkThumbnail(overscan: overscan, reflectionBlurRadius: reflectionBlurRadius)
                .scaleEffect(x: 1, y: -1)
                // Mirror the lift below the ground while keeping the fade fixed.
                .offset(y: displayedLift)
                .frame(height: reflectionHeight, alignment: .top)
                // The fade also clips the reflection's height; widen it to keep the slab edge.
                .mask {
                    LinearGradient(
                        stops: reflectionStops,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .padding(.horizontal, -overscan)
                }
                .overlay(alignment: .top) { contactShadow }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                // Reserve space for the visible reflection; let its faint tail overflow.
                .frame(height: 32, alignment: .top)
        }
    }

    @ViewBuilder
    private func draggableArtworkControl(overscan: CGFloat) -> some View {
        if let track {
            artworkControl(overscan: overscan)
                .trackDraggable(track)
                .contentHelp(artworkURL != nil ? "View full-size artwork or drag to a playlist" : "Drag to a playlist")
        } else {
            artworkControl(overscan: overscan)
        }
    }

    @ViewBuilder
    private func artworkControl(overscan: CGFloat) -> some View {
        if artworkURL != nil {
            Button {
                onShowArtwork()
            } label: {
                artworkThumbnail(overscan: overscan)
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentHelp("View full-size artwork")
            .accessibilityLabel(
                "View full-size artwork for \(title)"
            )
        } else {
            artworkThumbnail(overscan: overscan)
        }
    }

    // Occlusion where the cover meets the floor; it spreads and fades as the cover lifts.
    private var contactShadow: some View {
        Ellipse()
            .fill(.black.opacity(0.4 - 0.22 * min(liftProgress, 1)))
            .frame(width: size * (0.96 + 0.04 * liftProgress), height: 6 + 6 * liftProgress)
            .blur(radius: 4 + 5 * liftProgress)
            .offset(y: -3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func artworkThumbnail(overscan: CGFloat, reflectionBlurRadius: CGFloat? = nil) -> some View {
        TrackArtworkView(
            artworkURL: artworkURL,
            loader: loader,
            size: size + overscan * 2,
            rendition: .square500,
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            showsBorder: false,
            animatesChanges: animatesChanges,
            showsPlaceholderIcon: showsPlaceholderIcon
        )
        // Lay out at the face size; the glass masks the overscan that spills past it.
        .frame(width: size, height: size)
        .modifier(PlayerArtworkGlass(
            cornerRadius: cornerRadius,
            rotation: rotation,
            slabThickness: displayedSlabThickness,
            artworkOverscan: overscan
        ))
        .modifier(DetailArtworkReflectionBlur(
            radius: reflectionBlurRadius,
            cornerRadius: cornerRadius,
            maxShift: PlayerArtworkGlass.slabPadding(thickness: displayedSlabThickness, overscan: overscan)
        ))
        // A layer this far behind the face projects like the face shifted by depth * tan(angle);
        // positive angles bring the leading edge forward.
        .modifier(PlayerArtworkGlassSlab(
            shift: -displayedSlabThickness * tan(rotation * .pi / 180)
        ))
        // Match DetailArtworkRotation's springs so the edge tracks the turn.
        .animation(
            reduceMotion ? nil : (rotation == 0
                ? DetailArtworkMotion.rotationIn : DetailArtworkMotion.rotationOut),
            value: rotation
        )
        .environment(\.playerArtworkGlassParameters, glassParameters)
    }

    #if DEBUG
    private var slabControls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Artwork glass").font(.headline)
                    Spacer()
                    Button("Reset") {
                        let defaults = PlayerArtworkGlassParameters.detail
                        debugSlabThickness = 8
                        debugSlabDarkness = defaults.slabDarkness
                        debugSlabDepthShading = defaults.slabDepthShading
                        debugLipPosition = defaults.lipPosition
                        debugLipWidth = defaults.lipWidth
                        debugLipStrength = defaults.reflectionStrength
                        debugTurn = DetailArtworkTransform().y
                        debugFadeStart = DetailArtworkTransform().fadeStart
                        debugFadeEdgeOpacity = DetailArtworkTransform().fadeEdgeOpacity
                        debugFadeAngle = DetailArtworkTransform().fadeAngle
                        debugSpecularStrength = defaults.specularStrength
                        debugSpecularSoftness = defaults.specularSoftness
                    }
                }
                Text("Specular highlight").font(.subheadline.bold())
                slabSlider("Strength", value: $debugSpecularStrength, range: 0...0.5, step: 0.01)
                slabSlider("Softness", value: $debugSpecularSoftness, range: 0.05...0.6, step: 0.01)
                Divider()
                Text("Slab edge").font(.subheadline.bold())
                slabSlider("Thickness (pt)", value: $debugSlabThickness, range: 0...30, step: 0.5)
                slabSlider("Darkness", value: $debugSlabDarkness, range: 0...1, step: 0.01)
                slabSlider("Depth shading", value: $debugSlabDepthShading, range: 0...1, step: 0.01)
                slabSlider("Turn (°)", value: $debugTurn, range: 0...35, step: 0.5)
                Divider()
                Text("Edge fade").font(.subheadline.bold())
                slabSlider("Fade start", value: $debugFadeStart, range: 0...1, step: 0.01)
                slabSlider("Edge opacity", value: $debugFadeEdgeOpacity, range: 0...1, step: 0.01)
                slabSlider("Angle (°)", value: $debugFadeAngle, range: 0...90, step: 1)
                Divider()
                Text("Rim").font(.subheadline.bold())
                slabSlider("Lip position (pt)", value: $debugLipPosition, range: 0...8, step: 0.1)
                slabSlider("Lip width (pt)", value: $debugLipWidth, range: 0.1...6, step: 0.05)
                slabSlider("Lip strength", value: $debugLipStrength, range: 0...2, step: 0.05)
            }
            .padding(20)
        }
        .frame(width: 360, height: 600)
    }

    private func slabSlider(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step) { Text(title) }
        }
    }
    #endif
}

/// Blurs the reflection, then clips it to the face plus the slab edge so the silhouette
/// stays crisp while the edge animates with the turn.
private struct DetailArtworkReflectionBlur: ViewModifier {
    let radius: CGFloat?
    let cornerRadius: CGFloat
    // The glass caps the edge at its padding; match it so blur doesn't spill past the edge.
    let maxShift: CGFloat

    @Environment(\.playerArtworkGlassSlabShift) private var slabShift

    func body(content: Content) -> some View {
        if let radius {
            content
                .blur(radius: radius)
                .clipShape(SlabOutline(shift: min(max(slabShift, -maxShift), maxShift), cornerRadius: cornerRadius))
        } else {
            content
        }
    }
}

/// The face's rounded rect stretched sideways by the slab edge.
private struct SlabOutline: Shape {
    var shift: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: CGRect(
            x: rect.minX + min(shift, 0),
            y: rect.minY,
            width: rect.width + abs(shift),
            height: rect.height
        ))
    }
}

#if DEBUG
// Debug-only storage keys shared by the slab popover and DetailArtworkRotation.
enum DetailArtworkSlabTuning {
    static let thicknessKey = "debug.slab.thickness"
    static let darknessKey = "debug.slab.darkness"
    static let depthShadingKey = "debug.slab.depthShading"
    static let turnKey = "debug.slab.turn"
    static let lipPositionKey = "debug.slab.lipPosition"
    static let lipWidthKey = "debug.slab.lipWidth"
    static let lipStrengthKey = "debug.slab.lipStrength"
    static let fadeStartKey = "debug.slab.fadeStart"
    static let fadeEdgeOpacityKey = "debug.slab.fadeEdgeOpacity"
    static let fadeAngleKey = "debug.slab.fadeAngle"
}
#endif
