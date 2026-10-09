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
}

struct ArtworkVisualizerView: View {
    let shader: VisualizerShader
    let clothSettings: ClothSettings
    let pistonSettings: PistonSettings
    let trackProgress: Double
    let hasTrack: Bool
    @Binding var clothCamera: ClothCamera
    let spectrumBuffer: OpaquePointer
    let artworkURL: URL?
    let artworkLoader: ArtworkLoader
    var onArtworkAspectChange: (Float) -> Void

    @State private var artworkAccent: ArtworkAccent?
    @State private var artworkImage: CGImage?
    @State private var accentArtworkURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        MetalVisualizerView(
            shader: shader,
            clothSettings: clothSettings,
            pistonSettings: pistonSettings,
            trackProgress: trackProgress,
            hasTrack: hasTrack,
            clothCamera: $clothCamera,
            spectrumBuffer: spectrumBuffer,
            accent: accent,
            artworkImage: accentArtworkURL == artworkURL ? artworkImage : nil
        )
            .background {
                if shader == .cloth {
                    Color(.sRGB, red: 0.035, green: 0.045, blue: 0.06)
                } else {
                    visualizerBackdrop
                }
            }
            .task(id: artworkURL) {
                onArtworkAspectChange(1)
                artworkAccent = nil
                artworkImage = nil
                accentArtworkURL = nil
                guard let url = artworkURL else { return }
                async let image = try? artworkLoader.bitmap(for: url, rendition: .square1080)
                // Use the same source rendition as the waveform for a shared accent.
                async let color = try? artworkLoader.accentColor(for: url)
                let (loadedImage, loadedAccent) = await (image, color)
                guard !Task.isCancelled else { return }
                artworkImage = loadedImage
                artworkAccent = loadedAccent
                accentArtworkURL = url
                if let artworkImage {
                    onArtworkAspectChange(Float(artworkImage.width) / Float(artworkImage.height))
                }
            }
    }

    private var sourceAccent: ArtworkAccent {
        let fallback = ArtworkAccent.fallback
        return accentArtworkURL == artworkURL
            ? artworkAccent ?? fallback : fallback
    }

    private var visualizerBackdrop: some View {
        GeometryReader { geometry in
            let glowRGB = pistonSettings.backgroundGlowColor
            let backgroundRGB = pistonSettings.backgroundColor
            let glow = Color(.sRGBLinear, red: Double(glowRGB.x), green: Double(glowRGB.y), blue: Double(glowRGB.z))
            RadialGradient(
                stops: [
                    .init(color: glow, location: 0),
                    .init(color: glow.opacity(0.55), location: 0.35),
                    .init(color: glow.opacity(0.12), location: 0.7),
                    .init(color: .clear, location: 1)
                ],
                center: .center,
                startRadius: 0,
                endRadius: max(geometry.size.width, geometry.size.height) * 0.6
            )
            .background(Color(.sRGBLinear, red: Double(backgroundRGB.x),
                              green: Double(backgroundRGB.y), blue: Double(backgroundRGB.z)))
        }
        .allowsHitTesting(false)
    }

    private var accent: ArtworkAccent {
        sourceAccent.contrasted(
            isDark: colorScheme == .dark,
            increasedContrast: colorSchemeContrast == .increased
        )
    }
}

struct MetalVisualizerView: NSViewRepresentable {
    let shader: VisualizerShader
    let clothSettings: ClothSettings
    let pistonSettings: PistonSettings
    let trackProgress: Double
    let hasTrack: Bool
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
        renderer?.shader = shader
        renderer?.clothSettings = clothSettings
        renderer?.pistonSettings = pistonSettings
        renderer?.trackProgress = trackProgress
        renderer?.hasTrack = hasTrack
        renderer?.clothCamera = clothCamera
        renderer?.updateArtwork(artworkImage)
        view.onZoom = zoomHandler
        view.delegate = renderer
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        (view as? TransparentMetalView)?.onZoom = zoomHandler
        context.coordinator.renderer?.shader = shader
        context.coordinator.renderer?.clothSettings = clothSettings
        context.coordinator.renderer?.pistonSettings = pistonSettings
        context.coordinator.renderer?.trackProgress = trackProgress
        context.coordinator.renderer?.hasTrack = hasTrack
        context.coordinator.renderer?.clothCamera = clothCamera
        context.coordinator.renderer?.accent = accent
        context.coordinator.renderer?.updateArtwork(artworkImage)
    }

    private var zoomHandler: ((Float) -> Void)? {
        return { amount in
            clothCamera.zoom = min(2, max(0.2, clothCamera.zoom * exp(-amount)))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTKView, context: Context) -> CGSize? {
        // Follow SwiftUI's available space instead of the Metal view's previous frame.
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }
}
