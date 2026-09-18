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
                    .strokeBorder(.white.opacity(0.2), lineWidth: 1)
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
                    ProgressView("Loading artwork")
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
            .help("Close")
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

    @State private var image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        .opacity(0.38)
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
               let loaded = try? await loader.image(for: artworkURL) {
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

// Shared artwork treatment for track and playlist detail headers.
struct DetailArtworkView: View {
    let artworkURL: URL?
    let title: String
    let loader: ArtworkLoader
    let size: CGFloat
    var animatesChanges = false
    var showsPlaceholderIcon = true
    let onShowArtwork: () -> Void

    private let cornerRadius: CGFloat = 6
    private var reflectionHeight: CGFloat { size * 0.45 }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringArtwork = false

    var body: some View {
        VStack(spacing: 1) {
            artworkControl

            artworkThumbnail
                .scaleEffect(x: 1, y: -1)
                .frame(height: reflectionHeight, alignment: .top)
                .clipped()
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.45), location: 0),
                            .init(color: .black.opacity(0.24), location: 0.1),
                            .init(color: .black.opacity(0.12), location: 0.2),
                            .init(color: .black.opacity(0.055), location: 0.32),
                            .init(color: .black.opacity(0.02), location: 0.48),
                            .init(color: .black.opacity(0.005), location: 0.65),
                            .init(color: .clear, location: 0.85)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                // Reserve space for the visible reflection; let its faint tail overflow.
                .frame(height: 32, alignment: .top)
        }
    }

    @ViewBuilder
    private var artworkControl: some View {
        if artworkURL != nil {
            Button {
                onShowArtwork()
            } label: {
                artworkThumbnail
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onContentHover { isHoveringArtwork = $0 }
            .help("View full-size artwork")
            .accessibilityLabel(
                "View full-size artwork for \(title)"
            )
        } else {
            artworkThumbnail
        }
    }

    private var artworkThumbnail: some View {
        TrackArtworkView(
            artworkURL: artworkURL,
            loader: loader,
            size: size,
            rendition: .square500,
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            showsBorder: false,
            animatesChanges: animatesChanges,
            showsPlaceholderIcon: showsPlaceholderIcon
        )
        .scaleEffect(isHoveringArtwork && !reduceMotion ? 1.08 : 1)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .modifier(PlayerArtworkGlass(
            cornerRadius: cornerRadius,
            isHovering: isHoveringArtwork && !reduceMotion
        ))
        .animation(
            reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.75),
            value: isHoveringArtwork
        )
    }
}
