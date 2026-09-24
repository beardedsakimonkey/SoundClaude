import MetalKit
import ImageIO
import SwiftUI

private final class TransparentMetalView: MTKView {
    override var isOpaque: Bool { false }
    var onZoom: ((Float) -> Void)?
    var onPointerMove: ((SIMD2<Float>?) -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
        onPointerMove?(nil)
    }

    override func mouseMoved(with event: NSEvent) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), NSEvent.pressedMouseButtons == 0 else {
            onPointerMove?(nil)
            return
        }
        let x = Float((point.x - bounds.minX) / bounds.width) * 2 - 1
        let y = Float((point.y - bounds.minY) / bounds.height) * 2 - 1
        onPointerMove?(SIMD2(x, isFlipped ? -y : y))
    }

    override func mouseExited(with event: NSEvent) {
        onPointerMove?(nil)
    }


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
    @State private var backdropAccent = ArtworkAccent.fallback
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
            .background {
                if shader == .cloth {
                    clothBackdrop
                }
            }
            .task(id: artworkURL) {
                artworkAccent = nil
                artworkImage = nil
                accentArtworkURL = nil
                guard let url = artworkURL,
                      let data = try? await artworkLoader.data(for: url, rendition: .square1080) else {
                    guard !Task.isCancelled else { return }
                    transitionBackdrop(to: .fallback)
                    return
                }
                guard !Task.isCancelled else { return }
                artworkAccent = ArtworkAccent.extract(from: data)
                if let source = CGImageSourceCreateWithData(data as CFData, nil) {
                    artworkImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
                }
                accentArtworkURL = url
                transitionBackdrop(to: artworkAccent ?? .fallback)
            }
    }

    private func transitionBackdrop(to color: ArtworkAccent) {
        withAnimation(.easeInOut(duration: 0.9)) {
            backdropAccent = color
        }
    }

    private var sourceAccent: ArtworkAccent {
        let fallback = ArtworkAccent.fallback
        return accentArtworkURL == artworkURL
            ? artworkAccent ?? fallback : fallback
    }

    private var clothBackdrop: some View {
        GeometryReader { geometry in
            // Hold the previous color while the next artwork loads.
            let color = backdropAccent
            // Keep the spotlight visible even when the artwork accent is dark.
            let peak = max(0.01, max(color.red, max(color.green, color.blue)))
            // Mix 25% toward neutral while keeping the same peak brightness.
            let saturation = 0.75
            let glow = Color(
                .sRGB,
                red: (color.red / peak * saturation + 1 - saturation) * 0.65,
                green: (color.green / peak * saturation + 1 - saturation) * 0.65,
                blue: (color.blue / peak * saturation + 1 - saturation) * 0.65,
                opacity: 1
            )
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
            .modifier(AudioReactiveSpotlight(spectrumBuffer: spectrumBuffer))
            .background(Color(white: 0.008))
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

private struct AudioReactiveSpotlight: ViewModifier {
    let spectrumBuffer: OpaquePointer
    @State private var level = 0.0

    func body(content: Content) -> some View {
        content
            .opacity(0.35 + 0.65 * level)
            .task {
                var bands = [Float](repeating: 0, count: Int(SCSpectrumBandCount))
                var previousTime = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    let now = ProcessInfo.processInfo.systemUptime
                    let delta = now - previousTime
                    previousTime = now
                    var rms: Float = 0
                    let didRead = bands.withUnsafeMutableBufferPointer {
                        SCSpectrumBufferRead(spectrumBuffer, $0.baseAddress, &rms)
                    }
                    if didRead {
                        let target = rms.isFinite ? min(1, max(0, Double(rms) * 4)) : 0
                        // Follow rising amplitude quickly, then let the glow fade gently.
                        let response = target > level ? 0.08 : 0.35
                        level += (target - level) * (1 - exp(-delta / response))
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(33))
                    } catch {
                        return
                    }
                }
            }
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
        view.onPointerMove = { [weak renderer] point in
            renderer?.updateClothPointer(point)
        }
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
