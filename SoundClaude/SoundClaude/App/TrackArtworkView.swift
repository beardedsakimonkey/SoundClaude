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
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
        }
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

extension View {
    func artworkExpandIndicator(isHovering: Bool) -> some View {
        modifier(ArtworkExpandIndicator(isHovering: isHovering))
    }
}

private struct ArtworkExpandIndicator: ViewModifier {
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if isHovering {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(.black.opacity(0.65), in: Circle())
                        .padding(7)
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
        .background {
            ArtworkSheetOutsideClickView { dismiss() }
        }
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

private struct ArtworkSheetOutsideClickView: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onDismiss = onDismiss
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onDismiss: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
                [weak self] event in
                guard let self,
                      let sheet = self.window,
                      sheet.isVisible,
                      let parent = sheet.sheetParent,
                      parent.attachedSheet === sheet,
                      sheet.attachedSheet == nil,
                      let eventWindow = event.window,
                      eventWindow === parent || eventWindow === sheet else {
                    return event
                }

                let location = eventWindow.convertPoint(toScreen: event.locationInWindow)
                guard parent.frame.contains(location),
                      !sheet.frame.contains(location) else {
                    return event
                }

                // Consume the click so it cannot activate a control behind the sheet.
                self.stopMonitoring()
                self.onDismiss?()
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            stopMonitoring()
        }
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

    @State private var image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
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
            if !animatesChanges {
                image = nil
            }
            let nextImage: NSImage?
            if let artworkURL,
               let data = try? await loader.data(for: artworkURL) {
                nextImage = NSImage(data: data)
            } else {
                nextImage = nil
            }
            guard !Task.isCancelled else { return }
            withAnimation(animatesChanges && !reduceMotion ? .easeInOut(duration: 0.6) : nil) {
                image = nextImage
            }
        }
    }
}
