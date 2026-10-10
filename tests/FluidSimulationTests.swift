import AppKit
import MetalKit

@main
struct FluidSimulationTests {
    static func main() throws {
        testBandAttacks()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Fluid tests require Metal")
        }
        let source = try String(contentsOfFile: "SoundClaude/SoundClaude/Shaders/FluidVisualizer.metal", encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let simulation = try FluidSimulation(device: device, library: library, seed: 42)
        var now = 0.0
        var settings = FluidSettings()
        var size = CGSize(width: 960, height: 600)
        var touch = FluidTouch()
        func frame(bass: Float = 0, treble: Float = 0) -> MTLTexture {
            now += 1.0 / 60
            let command = queue.makeCommandBuffer()!
            let texture = simulation.encode(commandBuffer: command, size: size, settings: settings,
                bands: [Float](repeating: max(bass, treble), count: 64), touch: touch, now: now)!
            command.commit()
            command.waitUntilCompleted()
            precondition(command.status == .completed, "GPU error: \(String(describing: command.error))")
            return texture
        }
        func energy(_ texture: MTLTexture) -> Double {
            let rowBytes = texture.width * 8
            let buffer = device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared)!
            let command = queue.makeCommandBuffer()!
            let blit = command.makeBlitCommandEncoder()!
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                      to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
                      destinationBytesPerImage: buffer.length)
            blit.endEncoding()
            command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed)
            let values = buffer.contents().bindMemory(to: UInt16.self, capacity: buffer.length / 2)
            var sum = 0.0
            for i in 0..<(buffer.length / 2) where i % 4 != 3 {
                let value = Float(Float16(bitPattern: values[i]))
                precondition(value.isFinite && value >= 0, "Invalid dye value: \(value)")
                sum += Double(value)
            }
            return sum
        }
        var texture = frame()
        let initial = energy(texture)
        precondition(initial > 0, "Initial fluid must be visible without music")
        for _ in 0..<120 { texture = frame() }
        let faded = energy(texture)
        precondition(faded < initial * 0.7, "Silent fluid must fade")
        for i in 0..<240 {
            texture = frame(bass: i % 30 < 3 ? 0.8 : 0)
        }
        let driven = energy(texture)
        precondition(driven > faded, "Audio must inject visible dye")
        // Exercise the complete display pipeline under Metal validation, and save a preview.
        try preview(texture, simulation: simulation, device: device, queue: queue, library: library)
        for _ in 0..<240 { texture = frame() }
        let beforeTouch = energy(texture)
        touch.sequence = 1
        touch.point = SIMD2(0.5, 0.5)
        touch.delta = SIMD2(0.1, -0.1)
        let touched = energy(frame())
        precondition(touched > beforeTouch, "Pointer input must add dye")
        settings.curl = 50
        settings.force = 3
        settings.velocityDissipation = 0
        for _ in 0..<120 { texture = frame(bass: 1, treble: 1) }
        _ = energy(texture)
        simulation.suspend()
        now += 3600
        _ = energy(frame())
        for dimensions in [CGSize(width: 300, height: 900), CGSize(width: 3000, height: 100), size] {
            size = dimensions
            texture = frame()
            precondition(texture.width <= 2048 && texture.height <= 2048, "Grid must stay bounded")
            precondition(energy(texture) > 0, "Resize must initialize new textures")
        }
        let command = queue.makeCommandBuffer()!
        precondition(simulation.encode(commandBuffer: command, size: .zero, settings: settings,
            bands: [], touch: touch, now: now) == nil)
        print("Fluid GPU tests passed: audio, pointer, fade, stability, resize, and resume")
    }

    static func testBandAttacks() {
        for band in 0..<8 {
            var detector = FluidBandDetector()
            var levels = [Float](repeating: 0, count: 64)
            precondition(detector.update(bands: levels, delta: 1.0 / 60).isEmpty)
            for index in (band * 8)..<((band + 1) * 8) { levels[index] = 0.7 }
            let hits = detector.update(bands: levels, delta: 1.0 / 60)
            precondition(hits.count == 1 && hits[0].band == band, "Each band must detect its own attack")
            precondition(hits[0].color == FluidBandDetector.colors[band] * 0.15)
            for _ in 0..<60 {
                precondition(detector.update(bands: levels, delta: 1.0 / 60).isEmpty, "Sustained tones must not retrigger")
            }
            for _ in 0..<30 { _ = detector.update(bands: [Float](repeating: 0, count: 64), delta: 1.0 / 60) }
            precondition(detector.update(bands: levels, delta: 1.0 / 60).count == 1, "A later hit must retrigger")
            _ = detector.update(bands: [Float](repeating: 0, count: 64), delta: 1.0 / 60)
            precondition(detector.update(bands: levels, delta: 1.0 / 60).isEmpty, "Cooldown must suppress duplicate attacks")
        }
        var detector = FluidBandDetector()
        precondition(detector.update(bands: [Float](repeating: 0.8, count: 64), delta: 1.0 / 60).isEmpty,
                     "Entry must prime the detector")
        for _ in 0..<60 {
            precondition(detector.update(bands: [Float](repeating: .nan, count: 64), delta: 1.0 / 60).isEmpty)
        }
        precondition(detector.update(bands: [Float](repeating: 0.01, count: 64), delta: 1.0 / 60).isEmpty,
                     "Noise must not trigger splats")
        print("Fluid band attack tests passed")
    }

    static func preview(_ dye: MTLTexture, simulation: FluidSimulation, device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary) throws {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fluidVisualizerVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "fluidVisualizerFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 960, height: 600, mipmapped: false)
        td.usage = .renderTarget
        td.storageMode = .shared
        let target = device.makeTexture(descriptor: td)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = queue.makeCommandBuffer()!
        let settings = FluidSettings()
        let effects = simulation.encodeEffects(commandBuffer: command, dye: dye,
            size: CGSize(width: 960, height: 600), settings: settings)!
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(dye, index: 0)
        encoder.setFragmentTexture(effects.bloom, index: 1)
        encoder.setFragmentTexture(effects.rays, index: 2)
        var display = FluidDisplayUniforms(size: CGSize(width: 960, height: 600), settings: settings)
        encoder.setFragmentBytes(&display, length: MemoryLayout<FluidDisplayUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit(); command.waitUntilCompleted()
        precondition(command.status == .completed)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 960, pixelsHigh: 600,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 960 * 4, bitsPerPixel: 32)!
        target.getBytes(bitmap.bitmapData!, bytesPerRow: 960 * 4,
                        from: MTLRegionMake2D(0, 0, 960, 600), mipmapLevel: 0)
        let pixels = bitmap.bitmapData!
        var highlights = 0
        for index in 0..<(960 * 600) {
            if max(pixels[index * 4], max(pixels[index * 4 + 1], pixels[index * 4 + 2])) > 250 {
                highlights += 1
            }
        }
        precondition(highlights > 100, "Reference-style display must retain luminous highlights")
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/soundclaude-fluid-preview.png"))
    }
}
