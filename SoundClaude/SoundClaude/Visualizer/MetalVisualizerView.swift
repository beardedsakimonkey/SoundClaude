import MetalKit
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

    var onPan: ((SIMD2<Float>, CGSize) -> Void)?

    // Claim the right button so dragging pans instead of opening a menu.
    override func rightMouseDown(with event: NSEvent) {
        if onPan == nil { super.rightMouseDown(with: event) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let onPan else {
            super.rightMouseDragged(with: event)
            return
        }
        onPan(SIMD2(Float(event.deltaX), Float(event.deltaY)), bounds.size)
    }

    var onReset: (() -> Void)?

    override func otherMouseDown(with event: NSEvent) {
        // Button 2 is the middle button.
        guard event.buttonNumber == 2, let onReset else {
            super.otherMouseDown(with: event)
            return
        }
        onReset()
    }
}

struct ArtworkVisualizerView: View {
    let pistonSettings: PistonSettings
    @Binding var pistonCamera: PistonCamera
    let spectrumBuffer: OpaquePointer
    let artworkURL: URL?
    let artworkLoader: ArtworkLoader

    @State private var artworkAccent: ArtworkAccent?
    @State private var accentArtworkURL: URL?

    var body: some View {
        MetalVisualizerView(
            pistonSettings: pistonSettings,
            pistonCamera: $pistonCamera,
            spectrumBuffer: spectrumBuffer,
            accent: accent
        )
            .background {
                let rgb = pistonSettings.backgroundColor
                Color(.sRGBLinear, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
            }
            .task(id: artworkURL) {
                artworkAccent = nil
                accentArtworkURL = nil
                guard let url = artworkURL else { return }
                // Use the same source rendition as the waveform for a shared accent.
                let loadedAccent = try? await artworkLoader.accentColor(for: url)
                guard !Task.isCancelled else { return }
                artworkAccent = loadedAccent
                accentArtworkURL = url
            }
    }

    private var accent: ArtworkAccent {
        guard accentArtworkURL == artworkURL, let artworkAccent else {
            return ArtworkAccent(red: 0, green: 0, blue: 0)
        }
        return artworkAccent
    }

}

struct MetalVisualizerView: NSViewRepresentable {
    let pistonSettings: PistonSettings
    @Binding var pistonCamera: PistonCamera
    let spectrumBuffer: OpaquePointer
    let accent: ArtworkAccent

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
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
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
        renderer?.pistonSettings = pistonSettings
        renderer?.pistonCamera = pistonCamera
        view.onZoom = zoomHandler
        view.onPan = panHandler
        view.onReset = resetHandler
        view.delegate = renderer
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        (view as? TransparentMetalView)?.onZoom = zoomHandler
        (view as? TransparentMetalView)?.onPan = panHandler
        (view as? TransparentMetalView)?.onReset = resetHandler
        context.coordinator.renderer?.pistonSettings = pistonSettings
        context.coordinator.renderer?.pistonCamera = pistonCamera
        context.coordinator.renderer?.accent = accent
    }

    private var zoomHandler: (Float) -> Void {
        { amount in
            pistonCamera.zoom = min(2, max(0.2, pistonCamera.zoom * exp(-amount)))
        }
    }

    private var panHandler: (SIMD2<Float>, CGSize) -> Void {
        { delta, viewport in
            pistonCamera.pan(delta: delta, viewport: viewport)
        }
    }

    private var resetHandler: () -> Void {
        { pistonCamera = PistonCameraProjection.defaultCamera }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTKView, context: Context) -> CGSize? {
        // Follow SwiftUI's available space instead of the Metal view's previous frame.
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }
}
