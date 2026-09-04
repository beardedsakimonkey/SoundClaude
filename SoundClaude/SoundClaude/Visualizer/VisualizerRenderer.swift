import Foundation
import MetalKit

private struct VisualizerUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var energy: Float
}

final class VisualizerRenderer: NSObject, MTKViewDelegate {
    private let spectrumBuffer: OpaquePointer
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let metalBands: MTLBuffer
    private let startTime = ProcessInfo.processInfo.systemUptime

    init?(view: MTKView, spectrumBuffer: OpaquePointer) {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "visualizerVertex"),
              let fragment = library.makeFunction(name: "visualizerFragment"),
              let metalBands = device.makeBuffer(
                length: Int(SCSpectrumBandCount) * MemoryLayout<Float>.stride,
                options: .storageModeShared
              ) else {
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
        self.metalBands = metalBands
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

        let output = metalBands.contents().assumingMemoryBound(to: Float.self)
        var rms: Float = 0
        _ = SCSpectrumBufferRead(spectrumBuffer, output, &rms)
        var uniforms = VisualizerUniforms(
            resolution: SIMD2(
                Float(view.drawableSize.width),
                Float(view.drawableSize.height)
            ),
            time: Float(ProcessInfo.processInfo.systemUptime - startTime),
            energy: min(1, max(0, rms * 5))
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBuffer(metalBands, offset: 0, index: 0)
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
