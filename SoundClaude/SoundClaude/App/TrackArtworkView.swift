import AppKit
import SwiftUI

struct TrackArtworkView: View {
    let artworkURL: URL?
    let loader: ArtworkLoader
    let size: CGFloat
    let rendition: ArtworkLoader.Rendition

    @State private var image: NSImage?

    init(
        artworkURL: URL?,
        loader: ArtworkLoader,
        size: CGFloat,
        rendition: ArtworkLoader.Rendition = .source
    ) {
        self.artworkURL = artworkURL
        self.loader = loader
        self.size = size
        self.rendition = rendition
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .task(id: artworkURL) {
            image = nil
            guard let artworkURL,
                  let data = try? await loader.data(
                      for: artworkURL,
                      rendition: rendition
                  ),
                  !Task.isCancelled else {
                return
            }
            image = NSImage(data: data)
        }
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
