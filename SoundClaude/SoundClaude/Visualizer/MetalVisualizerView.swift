import MetalKit
import ImageIO
import SwiftUI

private final class TransparentMetalView: MTKView {
    override var isOpaque: Bool { false }
    var onZoom: ((Float) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard let onZoom else {
            super.scrollWheel(with: event)
            return
        }
        let scale: Float = event.hasPreciseScrollingDeltas ? 0.008 : 0.08
        onZoom(Float(event.scrollingDeltaY) * scale)
    }
}

struct ArtworkVisualizerView: View {
    let shader: VisualizerShader
    let inkPoolSettings: InkPoolSettings
    let clothSettings: ClothSettings
    @Binding var clothCamera: ClothCamera
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
            shader: shader,
            inkPoolSettings: inkPoolSettings,
            clothSettings: clothSettings,
            clothCamera: $clothCamera,
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
        let fallback = ArtworkAccent.fallback
        let color = accentArtworkURL == artworkURL
            ? artworkAccent ?? fallback : fallback
        return color.contrasted(
            isDark: colorScheme == .dark,
            increasedContrast: colorSchemeContrast == .increased
        )
    }
}

struct MetalVisualizerView: NSViewRepresentable {
    let shader: VisualizerShader
    let inkPoolSettings: InkPoolSettings
    let clothSettings: ClothSettings
    @Binding var clothCamera: ClothCamera
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
        view.depthStencilPixelFormat = .depth32Float
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
        renderer?.shader = shader
        renderer?.inkPoolSettings = inkPoolSettings
        renderer?.clothSettings = clothSettings
        renderer?.clothCamera = clothCamera
        renderer?.updateArtwork(artworkImage)
        view.onZoom = zoomHandler
        view.delegate = renderer
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        (view as? TransparentMetalView)?.onZoom = zoomHandler
        context.coordinator.renderer?.shader = shader
        context.coordinator.renderer?.inkPoolSettings = inkPoolSettings
        context.coordinator.renderer?.clothSettings = clothSettings
        context.coordinator.renderer?.clothCamera = clothCamera
        context.coordinator.renderer?.accent = accent
        context.coordinator.renderer?.updateArtwork(artworkImage)
    }

    private var zoomHandler: ((Float) -> Void)? {
        guard shader == .cloth else { return nil }
        return { amount in
            clothCamera.zoom = min(2, max(0.6, clothCamera.zoom * exp(-amount)))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTKView, context: Context) -> CGSize? {
        // Follow SwiftUI's available space instead of the Metal view's previous frame.
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }
}
