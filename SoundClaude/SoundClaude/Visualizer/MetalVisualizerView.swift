import MetalKit
import SwiftUI

private final class TransparentMetalView: MTKView {
    override var isOpaque: Bool { false }
}

struct ArtworkVisualizerView: View {
    let spectrumBuffer: OpaquePointer
    let artworkURL: URL?
    let artworkLoader: ArtworkLoader

    @State private var artworkAccent: ArtworkAccent?
    @State private var accentArtworkURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        MetalVisualizerView(spectrumBuffer: spectrumBuffer, accent: accent)
            .task(id: artworkURL) {
                artworkAccent = nil
                accentArtworkURL = nil
                guard let url = artworkURL,
                      let color = try? await artworkLoader.accentColor(for: url),
                      !Task.isCancelled else { return }
                artworkAccent = color
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
        view.delegate = renderer
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.accent = accent
    }
}
