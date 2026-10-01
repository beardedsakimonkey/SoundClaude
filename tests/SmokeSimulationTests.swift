import Foundation
import Metal

@main
struct SmokeSimulationTests {
    static func main() throws {
        let silence = [Float](repeating: 0, count: 64)
        let loud = [Float](repeating: 0.8, count: 64)
        var detector = SmokeOnsets()
        precondition(detector.advance(bands: silence, delta: 1 / 60, sensitivity: 1).allSatisfy { $0 == 0 })
        let strong = detector.advance(bands: loud, delta: 1 / 60, sensitivity: 1)
        precondition(strong.allSatisfy { $0 > 0 })
        for _ in 0..<120 { _ = detector.advance(bands: loud, delta: 1 / 60, sensitivity: 1) }
        precondition(detector.advance(bands: loud, delta: 1 / 60, sensitivity: 1).allSatisfy { $0 == 0 })
        precondition(detector.advance(bands: silence, delta: 1 / 60, sensitivity: 1).allSatisfy { $0 == 0 })
        var weakDetector = SmokeOnsets()
        let weak = weakDetector.advance(bands: Array(repeating: 0.1, count: 64), delta: 1 / 60, sensitivity: 1)
        precondition(zip(strong, weak).allSatisfy { $0 > $1 })
        var isolated = SmokeOnsets()
        var input = silence
        input[24..<32] = ArraySlice(repeating: 0.5, count: 8)
        let response = isolated.advance(bands: input, delta: 1 / 60, sensitivity: 1)
        precondition(response[3] > 0 && response.enumerated().allSatisfy { $0.offset == 3 || $0.element == 0 })
        precondition(isolated.advance(bands: [.nan, .infinity], delta: 1 / 60, sensitivity: 1).allSatisfy { $0.isFinite })

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal device required for smoke integration test")
        }
        let source = try String(contentsOfFile: "SoundClaude/SoundClaude/Shaders/SmokeVisualizer.metal", encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let simulation = try SmokeSimulation(device: device, library: library)
        func frame(_ index: Int, _ bands: [Float], width: Int = 192, height: Int = 128,
                   simulation: SmokeSimulation = simulation, settings: SmokeSettings = SmokeSettings()) -> MTLTexture {
            let command = queue.makeCommandBuffer()!
            let texture = simulation.encode(commandBuffer: command, width: width, height: height,
                                             bands: bands, settings: settings, time: Double(index) / 60)!
            command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed, "GPU error: \(String(describing: command.error))")
            return texture
        }
        func readback(_ texture: MTLTexture) -> [Float] {
            let length = texture.width * texture.height * 8
            let buffer = device.makeBuffer(length: length, options: .storageModeShared)!
            let command = queue.makeCommandBuffer()!
            let blit = command.makeBlitCommandEncoder()!
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                      to: buffer, destinationOffset: 0, destinationBytesPerRow: texture.width * 8,
                      destinationBytesPerImage: length)
            blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            let values = buffer.contents().bindMemory(to: Float16.self, capacity: length / 2)
            return (0..<(length / 2)).map { i in
                precondition(values[i].isFinite && values[i] >= 0)
                return Float(values[i])
            }
        }
        func energy(_ texture: MTLTexture) -> Float { readback(texture).reduce(0, +) }
        // Density-weighted mean row; smaller is higher on screen.
        func centroidY(_ texture: MTLTexture) -> Float {
            let values = readback(texture)
            var weighted: Float = 0, total: Float = 0
            for (index, alpha) in stride(from: 3, to: values.count, by: 4).map({ ($0 / 4, values[$0]) }) {
                weighted += Float(index / texture.width) * alpha; total += alpha
            }
            return weighted / max(total, 0.0001)
        }
        precondition(energy(frame(0, silence)) == 0)
        let puff = frame(1, loud)
        let initial = energy(puff)
        precondition(initial > 0)
        let renderDescriptor = MTLRenderPipelineDescriptor()
        renderDescriptor.vertexFunction = library.makeFunction(name: "smokeVisualizerVertex")
        renderDescriptor.fragmentFunction = library.makeFunction(name: "smokeVisualizerFragment")
        renderDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: renderDescriptor)
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 192, height: 128, mipmapped: false)
        targetDescriptor.storageMode = .shared
        targetDescriptor.usage = .renderTarget
        let target = device.makeTexture(descriptor: targetDescriptor)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let renderCommand = queue.makeCommandBuffer()!
        let render = renderCommand.makeRenderCommandEncoder(descriptor: pass)!
        render.setRenderPipelineState(pipeline)
        render.setFragmentTexture(puff, index: 3)
        var display = SmokeSettings().display
        render.setFragmentBytes(&display, length: MemoryLayout<SIMD4<Float>>.size, index: 3)
        render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        render.endEncoding(); renderCommand.commit(); renderCommand.waitUntilCompleted()
        precondition(renderCommand.status == .completed)
        var pixels = [UInt8](repeating: 0, count: 192 * 128 * 4)
        target.getBytes(&pixels, bytesPerRow: 192 * 4,
                        from: MTLRegionMake2D(0, 0, 192, 128), mipmapLevel: 0)
        precondition(stride(from: 0, to: pixels.count, by: 4).contains {
            max(pixels[$0], max(pixels[$0 + 1], pixels[$0 + 2])) > 180
        }, "Puffs should render bright color")
        var faded: MTLTexture!
        for i in 2...240 { faded = frame(i, silence) }
        precondition(energy(faded) < initial * 0.3, "Smoke must decay in silence")
        simulation.reset()
        precondition(energy(frame(241, silence)) == 0)
        precondition(energy(frame(242, silence, width: 128, height: 192)) == 0)

        // With injected motion disabled, only buoyancy can move the smoke, and it must move up.
        var still = SmokeSettings()
        still.force = 0
        still.buoyancy = 1.5
        let rising = try SmokeSimulation(device: device, library: library)
        let start = centroidY(frame(0, loud, simulation: rising, settings: still))
        var risen: MTLTexture!
        for i in 1...60 { risen = frame(i, silence, simulation: rising, settings: still) }
        precondition(centroidY(risen) < start - 2, "Buoyant smoke must rise")

        var gray = SmokeSettings()
        gray.saturation = 0
        let grayscale = try SmokeSimulation(device: device, library: library)
        let grayDye = readback(frame(0, loud, simulation: grayscale, settings: gray))
        precondition(stride(from: 0, to: grayDye.count, by: 4).allSatisfy { (i: Int) -> Bool in
            let (r, g, b) = (grayDye[i], grayDye[i + 1], grayDye[i + 2])
            return abs(r - g) < 0.01 && abs(g - b) < 0.01
        }, "Zero saturation must emit gray smoke")
        print("Smoke tests passed: onsets, strength, band isolation, GPU simulation and rendering, decay, reset, resize, buoyancy, saturation")
    }
}
