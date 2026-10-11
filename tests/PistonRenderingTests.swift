import Foundation
import Metal

@main struct PistonRenderingTests {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Piston rendering tests require scenePixels Metal device")
        }
        let source = try String(
            contentsOfFile: "SoundClaude/SoundClaude/Shaders/PistonVisualizer.metal", encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "pistonVisualizerVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "pistonVisualizerFragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba32Float
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.rasterSampleCount = 4
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        func texture(_ format: MTLPixelFormat, samples: Int) -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: 256, height: 256, mipmapped: false)
            descriptor.usage = .renderTarget
            descriptor.storageMode = samples > 1 || format == .depth32Float ? .private : .shared
            if samples > 1 {
                descriptor.textureType = .type2DMultisample
                descriptor.sampleCount = samples
            }
            return device.makeTexture(descriptor: descriptor)!
        }
        let scene = texture(.rgba32Float, samples: 1)
        let glow = texture(.rgba32Float, samples: 1)
        let multisampleColor = texture(.rgba32Float, samples: 4)
        let depth = texture(.depth32Float, samples: 4)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        let solidDepth = device.makeDepthStencilState(descriptor: depthDescriptor)!
        depthDescriptor.depthCompareFunction = .lessEqual
        depthDescriptor.isDepthWriteEnabled = false
        let glowDepth = device.makeDepthStencilState(descriptor: depthDescriptor)!
        let fallbackDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        fallbackDescriptor.usage = .shaderRead
        let fallback = device.makeTexture(descriptor: fallbackDescriptor)!
        let queue = device.makeCommandQueue()!
        var missing = 0
        var covered = 0
        // Tiny position changes reproduce idle simulation drift. The glow must cover
        // every fully covered rope pixel, despite its wider ribbon and separate pass.
        for frame in 0...32 {
            let occluded = frame == 32
            var points = [SIMD4<Float>](repeating: SIMD4(0.4, 0.2, 0.8, 0), count: 21)
            points[0] = SIMD4(-0.4 + Float(frame) * 0.00001, 1.8, -0.8, 0)
            let buffer = points.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)!
            }
            var uniforms = [SIMD4<Float>](repeating: .zero, count: 14)
            uniforms[0] = SIMD4(1, 0.3, 0.4, 3)
            uniforms[1] = SIMD4(repeating: 0.8)
            uniforms[2] = uniforms[1]
            uniforms[3] = SIMD4(0.02, 24, -1.65, 0)
            uniforms[4] = SIMD4(256, 256, 0, 0)
            uniforms[5].w = 2.7
            uniforms[10] = SIMD4(0.42, 0.05, 1, 1.5)
            let commandBuffer = queue.makeCommandBuffer()!
            for passIndex in 0..<2 {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = multisampleColor
                pass.colorAttachments[0].resolveTexture = passIndex == 0 ? scene : glow
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .multisampleResolve
                pass.depthAttachment.texture = depth
                pass.depthAttachment.loadAction = passIndex == 0 ? .clear : .load
                pass.depthAttachment.storeAction = .store
                pass.depthAttachment.clearDepth = occluded ? 0.5 : 1
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
                encoder.setRenderPipelineState(pipeline)
                encoder.setDepthStencilState(passIndex == 0 ? solidDepth : glowDepth)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setFragmentBuffer(buffer, offset: 0, index: 6)
                uniforms[3].w = passIndex == 0 ? 0 : 4
                uniforms.withUnsafeBytes {
                    encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
                    encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 4)
                }
                for i in 0..<3 { encoder.setFragmentTexture(fallback, index: i) }
                encoder.drawPrimitives(type: .triangle, vertexStart: 32 * 12 * 3, vertexCount: 6)
                encoder.endEncoding()
            }
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            precondition(commandBuffer.status == .completed, "GPU failed: \(String(describing:commandBuffer.error))")
            var scenePixels = [Float](repeating: 0, count: 256 * 256 * 4)
            var glowPixels = scenePixels
            scene.getBytes(
                &scenePixels, bytesPerRow: 256 * 16, from: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0)
            glow.getBytes(
                &glowPixels, bytesPerRow: 256 * 16, from: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0)
            precondition(scenePixels.allSatisfy(\.isFinite) && glowPixels.allSatisfy(\.isFinite))
            if occluded {
                precondition(glowPixels.allSatisfy { $0 == 0 }, "Glow must remain hidden behind foreground geometry")
            }
            for pixel in 0..<256 * 256 where scenePixels[pixel * 4 + 3] > 0.99 {
                covered += 1
                // Idle brightness and the halo profile give at least 0.05 alpha here.
                if glowPixels[pixel * 4 + 3] < 0.04 { missing += 1 }
            }
        }
        precondition(covered > 0, "Fixture must draw scenePixels visible rope")
        precondition(
            missing == 0, "Glow failed its own rope depth test at \(missing) of \(covered) pixels")
        // Exercise the sky pass at normal, horizontal, and nearly vertical views.
        // Zero strength and a nearer opaque depth must both hide the shafts.
        var fixedSkyPixels: [Float]?
        for (pitch, strength, blocked, height) in [(Float(0.5), Float(1), false, Float(0.8)),
                                            (0.5, 1, false, 5.8),
                                            (0, 1, false, 0.8), (1.56, 1, false, 0.8),
                                            (0.5, 0, false, 0.8), (0.5, 1, true, 0.8)] {
            var uniforms = [SIMD4<Float>](repeating: .zero, count: 13)
            uniforms[0] = SIMD4(1, 0.3, pitch, 20)
            uniforms[1] = SIMD4(repeating: height)
            uniforms[2] = SIMD4(repeating: height)
            uniforms[3] = SIMD4(0.02, 24, -1.65, 5)
            uniforms[4] = SIMD4(256, 256, 0, 0)
            uniforms[5].w = 2.7
            uniforms[9].z = strength
            uniforms[9].w = 1
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = multisampleColor
            pass.colorAttachments[0].resolveTexture = scene
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .multisampleResolve
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .dontCare
            pass.depthAttachment.clearDepth = blocked ? 0.5 : 1
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(glowDepth)
            let dummy = device.makeBuffer(length: 16)!
            encoder.setVertexBuffer(dummy, offset: 0, index: 0)
            encoder.setFragmentBuffer(dummy, offset: 0, index: 6)
            uniforms.withUnsafeBytes {
                encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
                encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 4)
            }
            for i in 0..<3 { encoder.setFragmentTexture(fallback, index: i) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            precondition(command.status == .completed, "Sky pass GPU failure")
            var pixels = [Float](repeating: 0, count: 256 * 256 * 4)
            scene.getBytes(&pixels, bytesPerRow: 256 * 16,
                           from: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0)
            precondition(pixels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
            if pitch == 0.5 && strength == 1 && !blocked {
                if let fixedSkyPixels {
                    precondition(pixels == fixedSkyPixels,
                                 "Piston height must not change sky beam positions or brightness")
                } else {
                    fixedSkyPixels = pixels
                }
            }
            if pitch == 0 && strength == 1 && !blocked {
                // Project a point on the fifth shaft below the former cap-height
                // cutoff. Its soft tail must remain visible above the floor.
                let x: Float = 0.925
                let distance: Float = 20 + sin(0.3) * x
                let pixelX = Int((cos(0.3) * x * 2.1 / distance + 1) * 128)
                let pixelY = Int((1 + 2.1 / distance) * 128) // World y = 0.
                precondition(pixels[(pixelY * 256 + pixelX) * 4 + 3] > 0.02,
                             "Sky beams must fade below resting cap height without a hard cutoff")
            }
            if strength == 0 || blocked {
                precondition(pixels.allSatisfy { $0 == 0 }, "Disabled or occluded shafts must disappear")
            } else {
                precondition(pixels.max()! > 0.05, "Sky shafts must be visible")
                for pixel in 0..<256 * 256 {
                    let rgba = Array(pixels[(pixel * 4)..<(pixel * 4 + 4)])
                    precondition(rgba.prefix(3).allSatisfy { $0 <= rgba[3] }, "Haze must be premultiplied")
                }
            }
        }
        print("Piston rendering tests passed (\(covered) rope pixels, plus foreground occlusion and sky spotlights)")
    }
}
