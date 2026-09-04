import Foundation
import MetalKit

private struct VisualizerUniforms {
    var energy: Float
}

final class VisualizerRenderer: NSObject, MTKViewDelegate {
    private let spectrumBuffer: OpaquePointer
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var bands = [Float](repeating: 0, count: Int(SCSpectrumBandCount))

    init?(view: MTKView, spectrumBuffer: OpaquePointer) {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "visualizerVertex"),
              let fragment = library.makeFunction(name: "visualizerFragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Audio visualizer"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        do {
            pipelineState = try device.makeRenderPipelineState(
                descriptor: descriptor
            )
        } catch {
            return nil
        }

        self.spectrumBuffer = spectrumBuffer
        self.commandQueue = commandQueue
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPassDescriptor
              ) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        var rms: Float = 0
        bands.withUnsafeMutableBufferPointer { pointer in
            _ = SCSpectrumBufferRead(spectrumBuffer, pointer.baseAddress, &rms)
            encoder.setFragmentBytes(
                pointer.baseAddress!,
                length: pointer.count * MemoryLayout<Float>.stride,
                index: 0
            )
        }
        var uniforms = VisualizerUniforms(
            energy: min(1, max(0, rms * 5))
        )

        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<VisualizerUniforms>.stride,
            index: 1
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
