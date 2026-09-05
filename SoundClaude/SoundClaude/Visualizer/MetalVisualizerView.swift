import MetalKit
import SwiftUI

private final class TransparentMetalView: MTKView {
    override var isOpaque: Bool { false }
}

struct MetalVisualizerView: NSViewRepresentable {
    let spectrumBuffer: OpaquePointer

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
            spectrumBuffer: spectrumBuffer
        )
        context.coordinator.renderer = renderer
        view.delegate = renderer
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}
