import MetalKit
import SwiftUI

struct MetalVisualizerView: NSViewRepresentable {
    let spectrumBuffer: OpaquePointer

    final class Coordinator {
        var renderer: VisualizerRenderer?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(
            red: 0.025,
            green: 0.03,
            blue: 0.055,
            alpha: 1
        )
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
