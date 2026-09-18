import MetalKit
import ImageIO
import SwiftUI

private final class TransparentMetalView: MTKView {
    override var isOpaque: Bool { false }
}

struct ArtworkVisualizerView: View {
    let spectrumBuffer: OpaquePointer
    let artworkURL: URL?
    let artworkLoader: ArtworkLoader

    @State private var artworkAccent: ArtworkAccent?
    @State private var artworkImage: CGImage?
    @State private var accentArtworkURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        MetalVisualizerView(
            spectrumBuffer: spectrumBuffer,
            accent: accent,
            artworkImage: accentArtworkURL == artworkURL ? artworkImage : nil
        )
            .task(id: artworkURL) {
                artworkAccent = nil
                artworkImage = nil
                accentArtworkURL = nil
                guard let url = artworkURL,
                      let data = try? await artworkLoader.data(for: url, rendition: .square1080),
                      !Task.isCancelled else { return }
                artworkAccent = ArtworkAccent.extract(from: data)
                if let source = CGImageSourceCreateWithData(data as CFData, nil) {
                    artworkImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
                }
                accentArtworkURL = url
            }
    }

    private var accent: ArtworkAccent {
        let blue = NSColor.systemBlue.usingColorSpace(.sRGB)!
        let fallback = ArtworkAccent(
            red: blue.redComponent, green: blue.greenComponent, blue: blue.blueComponent
        )
        let color = accentArtworkURL == artworkURL
            ? artworkAccent ?? fallback : fallback
        return color.contrasted(
            isDark: colorScheme == .dark,
            increasedContrast: colorSchemeContrast == .increased
        )
    }
}

struct MetalVisualizerView: NSViewRepresentable {
    let spectrumBuffer: OpaquePointer
    let accent: ArtworkAccent
    let artworkImage: CGImage?

    final class Coordinator {
        var renderer: VisualizerRenderer?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = TransparentMetalView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )
        view.layer?.isOpaque = false
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        let maximum = NSScreen.main?.maximumFramesPerSecond ?? 60
        view.preferredFramesPerSecond = maximum >= 120 ? 120 : 60

        let renderer = VisualizerRenderer(
            view: view,
            spectrumBuffer: spectrumBuffer,
            accent: accent
        )
        context.coordinator.renderer = renderer
        renderer?.updateArtwork(artworkImage)
        view.delegate = renderer
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.accent = accent
        context.coordinator.renderer?.updateArtwork(artworkImage)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTKView, context: Context) -> CGSize? {
        // Follow SwiftUI's available space instead of the Metal view's previous frame.
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }
}
