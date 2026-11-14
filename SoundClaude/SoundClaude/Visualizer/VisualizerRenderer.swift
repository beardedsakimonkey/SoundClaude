import Foundation
import MetalKit
import MetalPerformanceShaders
import simd

final class VisualizerRenderer: NSObject, MTKViewDelegate {
    var accent: ArtworkAccent
    private var displayedAccent: SIMD3<Float>
    private var accentTransitionFrom: SIMD3<Float>
    private var accentTransitionTarget: SIMD3<Float>
    private var accentTransitionStart: Double?
    var pistonSettings = PistonSettings()
    var pistonCamera = PistonCameraProjection.defaultCamera

    private var shadowMask: MTLTexture?
    private var shadowBlur: MTLTexture?
    private var shadowDepth: MTLTexture?
    private var pistonRopeShadow: MTLTexture?
    private var pistonRopeShadowDepth: MTLTexture?
    private var pistonReflection: MTLTexture?
    private var pistonReflectionBlur: MTLTexture?
    private var pistonReflectionDepth: MTLTexture?
    private var pistonBloomMultisampleMask: MTLTexture?
    private var pistonBloomMask: MTLTexture?
    private var pistonBloomBlur: MTLTexture?
    private var pistonBloomCompositePipeline: MTLRenderPipelineState?
    private var gradeSource: MTLTexture?
    private var gradeMultisample: MTLTexture?
    private var sceneDepth: MTLTexture?
    private var gradePipeline: MTLRenderPipelineState?
    private var gradeDitherFrame: UInt32 = 0
    private var pistons = PistonSimulation()
    private var lastPistonTime: Double?
    private let glowDepthState: MTLDepthStencilState?
    private let depthState: MTLDepthStencilState?
    private let spectrumBuffer: OpaquePointer
    private let commandQueue: MTLCommandQueue
    private let fallbackTexture: MTLTexture
    private struct Pipelines {
        let scene: MTLRenderPipelineState
        let shadow: MTLRenderPipelineState
        let glow: MTLRenderPipelineState
    }

    private let sceneSampleCount: Int
    private let pipelines: Pipelines
    private var bands = [Float](repeating: 0, count: Int(SCSpectrumBandCount))

    init?(view: MTKView, spectrumBuffer: OpaquePointer, accent: ArtworkAccent) {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            return nil
        }

        sceneSampleCount = device.supportsTextureSampleCount(4) ? 4
            : (device.supportsTextureSampleCount(2) ? 2 : 1)
        do {
            pipelines = try Self.makePipelines(
                device: device, library: library, sampleCount: sceneSampleCount)
            let bloom = MTLRenderPipelineDescriptor()
            bloom.label = "Piston bloom composite"
            bloom.vertexFunction = library.makeFunction(name: "pistonBloomVertex")
            bloom.fragmentFunction = library.makeFunction(name: "pistonBloomFragment")
            let attachment = bloom.colorAttachments[0]!
            attachment.pixelFormat = .rgba16Float
            // Screen blend with matching alpha keeps the transparent layer premultiplied.
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceColor
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pistonBloomCompositePipeline = try device.makeRenderPipelineState(descriptor: bloom)
            let grade = MTLRenderPipelineDescriptor()
            grade.label = "Visualizer color grade"
            grade.vertexFunction = library.makeFunction(name: "visualizerGradeVertex")
            grade.fragmentFunction = library.makeFunction(name: "visualizerGradeFragment")
            grade.colorAttachments[0].pixelFormat = view.colorPixelFormat
            gradePipeline = try device.makeRenderPipelineState(descriptor: grade)
        } catch {
            return nil
        }

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depth)
        depth.depthCompareFunction = .lessEqual
        depth.isDepthWriteEnabled = false
        glowDepthState = device.makeDepthStencilState(descriptor: depth)
        self.accent = accent
        let rgb = SIMD3<Float>(Float(accent.red), Float(accent.green), Float(accent.blue))
        displayedAccent = rgb
        accentTransitionFrom = rgb
        accentTransitionTarget = rgb
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        textureDescriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        var white: UInt32 = 0xFFFFFFFF
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
            withBytes: &white, bytesPerRow: 4
        )
        fallbackTexture = texture
        self.spectrumBuffer = spectrumBuffer
        self.commandQueue = commandQueue
        super.init()
    }

    private static func makePipelines(
        device: MTLDevice, library: MTLLibrary, sampleCount: Int
    ) throws -> Pipelines {
        let scene = try makePipeline(device: device, library: library, sampleCount: sampleCount)
        // Shadow masks are blurred separately and keep single-sample attachments.
        let shadow = sampleCount == 1 ? scene : try makePipeline(device: device, library: library)
        let glow = try makePipeline(device: device, library: library,
                                    sampleCount: sampleCount, glowBlend: true)
        return Pipelines(scene: scene, shadow: shadow, glow: glow)
    }

    private static func makePipeline(
        device: MTLDevice, library: MTLLibrary,
        sampleCount: Int = 1, glowBlend: Bool = false
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.rasterSampleCount = sampleCount
        descriptor.label = "Audio visualizer: Pistons"
        descriptor.vertexFunction = library.makeFunction(name: "pistonVisualizerVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "pistonVisualizerFragment")
        guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil else {
            throw NSError(domain: "VisualizerShader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Shader must define pistonVisualizerVertex and pistonVisualizerFragment."
            ])
        }
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        descriptor.depthAttachmentPixelFormat = .depth32Float
        if glowBlend, let attachment = descriptor.colorAttachments[0] {
            // Screen blend with matching alpha keeps the transparent layer premultiplied.
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceColor
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private typealias PistonFrame = (positions: MTLBuffer, uniforms: [SIMD4<Float>], vertexCount: Int)

    private func preparePistons(in view: MTKView) -> PistonFrame? {
        let now = ProcessInfo.processInfo.systemUptime
        pistons.settings = pistonSettings
        let delta = lastPistonTime.map { now - $0 } ?? PistonSimulation.step
        pistons.advance(delta: delta, bands: bands)
        lastPistonTime = now
        var uniforms = [PistonCameraProjection.camera(
            size: view.drawableSize, yaw: pistonCamera.yaw,
            pitch: pistonCamera.pitch, zoom: pistonCamera.zoom, targetHeight: pistonCamera.target.y)]
        uniforms.append(SIMD4(pistons.heights[0], pistons.heights[1], pistons.heights[2], pistons.heights[3]))
        uniforms.append(SIMD4(pistons.heights[4], pistons.heights[5], pistons.heights[6], pistons.heights[7]))
        uniforms.append(SIMD4<Float>(pistonSettings.ropeThickness * 0.5, Float(pistonSettings.stringsPerPiston), 0, 0))
        let buffer = pistons.positions.withUnsafeBytes { bytes in
            view.device?.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count)
        }
        guard let buffer else { return nil }
        // Match the floor used by the rope solver.
        uniforms[3].z = -1.65
        uniforms.append(SIMD4<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height),
                                     pistonSettings.restingRopeBrightness, pistonSettings.restingRopeGlow))
        uniforms.append(SIMD4<Float>(pistonSettings.stripeThickness, pistonSettings.stripeFrequency,
                                     pistonSettings.headTwist * .pi / 180, pistonSettings.travel))
        uniforms.append(SIMD4<Float>(pistonSettings.stripeColor, 0))
        uniforms.append(SIMD4<Float>(pistonSettings.metalColor, pistonSettings.roughness))
        uniforms.append(SIMD4<Float>(pistonSettings.baseColor, pistonSettings.metallic))
        uniforms.append(SIMD4<Float>(pistonSettings.reflectionStrength, pistonSettings.edgeSoftness,
                                     pistonSettings.neutralRopeGlow, pistonSettings.bloomStrength))
        uniforms.append(SIMD4<Float>(pistonSettings.groundColor, 0))
        uniforms.append(SIMD4<Float>(pistonSettings.skyAccentColor(for: displayedArtworkAccent), 0))
        uniforms.append(SIMD4<Float>(pistonSettings.lightColor(for: displayedArtworkAccent), 0))
        uniforms.append(SIMD4<Float>(pistonSettings.groundHighlightStrength, pistonSettings.groundHighlightSoftness,
                                     pistonSettings.groundFogStart, pistonSettings.groundFogDensity))
        uniforms.append(SIMD4<Float>(VisualizerGrade.sRGBEncoded(pistonSettings.backgroundColor), 0))
        uniforms.append(SIMD4<Float>(pistonSettings.lightDirection, 0))
        uniforms.append(SIMD4<Float>(pistonCamera.target, 0))
        // Wrap the clock hourly to keep the sky's slow drift precise in a Float.
        uniforms.append(SIMD4<Float>(pistonSettings.skyGlow, pistonSettings.skyStars, pistonSettings.skyNebula,
                                     Float(now.truncatingRemainder(dividingBy: 3600))))
        uniforms.append(SIMD4<Float>(pistonSettings.groundReflection, pistonSettings.groundRopeLight,
                                     pistonSettings.groundTileSeams, pistonSettings.ropeLength))
        return (buffer, uniforms, PistonSimulation.count *
            (32 * 12 * 3 + pistonSettings.stringsPerPiston * (PistonSimulation.segments * 6 + 12 * 8 * 6)))
    }

    private func encodePistonRopeShadow(
        in view: MTKView, commandBuffer: MTLCommandBuffer, frame: PistonFrame
    ) -> MTLTexture? {
        guard let device = view.device else { return nil }
        if pistonRopeShadow == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 2048, height: 2048, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            pistonRopeShadow = device.makeTexture(descriptor: descriptor)
            descriptor.pixelFormat = .depth32Float
            descriptor.usage = .renderTarget
            pistonRopeShadowDepth = device.makeTexture(descriptor: descriptor)
        }
        guard let texture = pistonRopeShadow, let depth = pistonRopeShadowDepth else { return nil }
        let pipeline = pipelines.shadow
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.label = "Piston cap and rope shadows"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(frame.positions, offset: 0, index: 0)
        encoder.setFragmentBuffer(frame.positions, offset: 0, index: 6)
        encoder.setFragmentTexture(fallbackTexture, index: 1)
        encoder.setFragmentTexture(fallbackTexture, index: 2)
        encoder.setFragmentTexture(fallbackTexture, index: 3)
        var uniforms = frame.uniforms
        uniforms[3].w = 3
        uniforms.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
        }
        let solids = 32 * 12 * 3
        let ropes = pistonSettings.stringsPerPiston * PistonSimulation.segments * 6
        let bobs = pistonSettings.stringsPerPiston * 12 * 8 * 6
        for piston in 0..<PistonSimulation.count {
            encoder.drawPrimitives(type: .triangle,
                                   vertexStart: piston * (solids + ropes + bobs) + solids - 32 * 12,
                                   vertexCount: ropes + bobs + 32 * 12)
        }
        encoder.endEncoding()
        return texture
    }

    /// Draws the scene upside down below the floor, blurred for the floor to mirror.
    private func encodePistonReflection(
        in view: MTKView, commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState, frame: PistonFrame, ropeShadow: MTLTexture?
    ) -> MTLTexture? {
        guard pistonSettings.groundReflection > 0, let device = view.device else { return nil }
        // The blur hides the reduced resolution.
        let scale = min(0.5, 1024 / max(1, max(view.drawableSize.width, view.drawableSize.height)))
        let width = max(1, Int(view.drawableSize.width * scale))
        let height = max(1, Int(view.drawableSize.height * scale))
        if pistonReflection?.width != width || pistonReflection?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            pistonReflection = device.makeTexture(descriptor: descriptor)
            pistonReflectionBlur = device.makeTexture(descriptor: descriptor)
            descriptor.pixelFormat = .depth32Float
            descriptor.usage = .renderTarget
            pistonReflectionDepth = device.makeTexture(descriptor: descriptor)
        }
        guard let texture = pistonReflection, let blurred = pistonReflectionBlur,
              let depth = pistonReflectionDepth else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.label = "Piston floor reflection"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(frame.positions, offset: 0, index: 0)
        encoder.setFragmentBuffer(frame.positions, offset: 0, index: 6)
        encoder.setFragmentTexture(fallbackTexture, index: 1)
        encoder.setFragmentTexture(ropeShadow ?? fallbackTexture, index: 2)
        encoder.setFragmentTexture(fallbackTexture, index: 3)
        var uniforms = frame.uniforms
        uniforms[3].w = -1
        uniforms.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: frame.vertexCount)
        encoder.endEncoding()
        let blur = MPSImageGaussianBlur(device: device, sigma: max(1, Float(min(width, height)) * 0.004))
        blur.edgeMode = .clamp
        blur.encode(commandBuffer: commandBuffer, sourceTexture: texture, destinationTexture: blurred)
        return blurred
    }

    private func encodePistonShadow(
        in view: MTKView, commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState, frame: PistonFrame
    ) -> MTLTexture? {
        encodeShadow(in: view, commandBuffer: commandBuffer) { encoder in
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(frame.positions, offset: 0, index: 0)
            encoder.setFragmentBuffer(frame.positions, offset: 0, index: 6)
            encoder.setFragmentTexture(fallbackTexture, index: 1)
            encoder.setFragmentTexture(fallbackTexture, index: 2)
            encoder.setFragmentTexture(fallbackTexture, index: 3)
            var uniforms = frame.uniforms
            uniforms[3].w = 1
            uniforms.withUnsafeBytes { bytes in
                encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: frame.vertexCount)
        }
    }

    private func encodeShadow(
        in view: MTKView, commandBuffer: MTLCommandBuffer,
        drawMask: (MTLRenderCommandEncoder) -> Void
    ) -> MTLTexture? {
        guard let device = view.device else { return nil }
        // Cap offscreen cost and keep blur softness proportional to the viewport.
        let maximumDimension: CGFloat = 512
        let scale = min(1, maximumDimension / max(1, max(view.drawableSize.width, view.drawableSize.height)))
        let width = max(1, Int(view.drawableSize.width * scale))
        let height = max(1, Int(view.drawableSize.height * scale))
        if shadowMask?.width != width || shadowMask?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            shadowMask = device.makeTexture(descriptor: descriptor)
            shadowBlur = device.makeTexture(descriptor: descriptor)
            descriptor.pixelFormat = .depth32Float
            descriptor.usage = .renderTarget
            shadowDepth = device.makeTexture(descriptor: descriptor)
        }
        guard let shadowMask, let shadowBlur, let shadowDepth else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = shadowMask
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.depthAttachment.texture = shadowDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.label = "Visualizer wall shadow mask"
        drawMask(encoder)
        encoder.endEncoding()
        let blur = MPSImageGaussianBlur(device: device, sigma: max(1, Float(min(width, height)) * 0.008))
        blur.edgeMode = .zero
        blur.encode(commandBuffer: commandBuffer, sourceTexture: shadowMask, destinationTexture: shadowBlur)
        return shadowBlur
    }

    private func encodePistonBloom(
        in view: MTKView, commandBuffer: MTLCommandBuffer, frame: PistonFrame,
        depth: MTLTexture, destination: MTLTexture
    ) {
        guard pistonSettings.bloomStrength > 0 else { return }
        guard let device = view.device,
              let compositePipeline = pistonBloomCompositePipeline else { return }
        let width = destination.width, height = destination.height
        if pistonBloomMask?.width != width || pistonBloomMask?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            pistonBloomMask = device.makeTexture(descriptor: descriptor)
            pistonBloomBlur = device.makeTexture(descriptor: descriptor)
            if sceneSampleCount > 1 {
                descriptor.textureType = .type2DMultisample
                descriptor.sampleCount = sceneSampleCount
                descriptor.usage = .renderTarget
                pistonBloomMultisampleMask = device.makeTexture(descriptor: descriptor)
            }
        }
        guard let mask = pistonBloomMask, let blurred = pistonBloomBlur else { return }
        // Use the scene depth so hidden ropes cannot seed the bloom.
        let sourcePass = MTLRenderPassDescriptor()
        if sceneSampleCount > 1 {
            guard let multisampleMask = pistonBloomMultisampleMask else { return }
            sourcePass.colorAttachments[0].texture = multisampleMask
            sourcePass.colorAttachments[0].resolveTexture = mask
            sourcePass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            sourcePass.colorAttachments[0].texture = mask
            sourcePass.colorAttachments[0].storeAction = .store
        }
        sourcePass.colorAttachments[0].loadAction = .clear
        sourcePass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        sourcePass.depthAttachment.texture = depth
        sourcePass.depthAttachment.loadAction = .load
        sourcePass.depthAttachment.storeAction = .dontCare
        guard let source = commandBuffer.makeRenderCommandEncoder(descriptor: sourcePass) else { return }
        source.label = "Piston bloom source"
        source.setRenderPipelineState(pipelines.glow)
        source.setDepthStencilState(glowDepthState)
        source.setVertexBuffer(frame.positions, offset: 0, index: 0)
        source.setFragmentBuffer(frame.positions, offset: 0, index: 6)
        source.setFragmentTexture(fallbackTexture, index: 1)
        source.setFragmentTexture(fallbackTexture, index: 2)
        source.setFragmentTexture(fallbackTexture, index: 3)
        var uniforms = frame.uniforms
        uniforms[3].w = 4
        uniforms.withUnsafeBytes { bytes in
            source.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            source.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
        }
        let solids = 32 * 12 * 3
        let ropes = pistonSettings.stringsPerPiston * PistonSimulation.segments * 6
        let bobs = pistonSettings.stringsPerPiston * 12 * 8 * 6
        for piston in 0..<PistonSimulation.count {
            source.drawPrimitives(type: .triangle,
                                  vertexStart: piston * (solids + ropes + bobs) + solids, vertexCount: ropes + bobs)
        }
        source.endEncoding()
        let blur = MPSImageGaussianBlur(device: device, sigma: max(2, Float(min(width, height)) * 0.006))
        blur.edgeMode = .zero
        blur.encode(commandBuffer: commandBuffer, sourceTexture: mask, destinationTexture: blurred)
        let compositePass = MTLRenderPassDescriptor()
        compositePass.colorAttachments[0].texture = destination
        compositePass.colorAttachments[0].loadAction = .load
        compositePass.colorAttachments[0].storeAction = .store
        guard let composite = commandBuffer.makeRenderCommandEncoder(descriptor: compositePass) else { return }
        composite.label = "Piston bloom composite"
        composite.setRenderPipelineState(compositePipeline)
        composite.setFragmentTexture(blurred, index: 0)
        composite.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        composite.endEncoding()
    }

    private func makeScenePass(in view: MTKView, size: MTLTexture) -> MTLRenderPassDescriptor? {
        guard let device = view.device else { return nil }
        let width = size.width, height = size.height
        if gradeSource?.width != width || gradeSource?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            gradeSource = device.makeTexture(descriptor: descriptor)
            descriptor.usage = .renderTarget
            if sceneSampleCount > 1 {
                descriptor.textureType = .type2DMultisample
                descriptor.sampleCount = sceneSampleCount
                gradeMultisample = device.makeTexture(descriptor: descriptor)
            }
            descriptor.pixelFormat = .depth32Float
            sceneDepth = device.makeTexture(descriptor: descriptor)
        }
        guard let source = gradeSource, let depth = sceneDepth else { return nil }
        let pass = MTLRenderPassDescriptor()
        if sceneSampleCount > 1 {
            guard let multisample = gradeMultisample else { return nil }
            pass.colorAttachments[0].texture = multisample
            pass.colorAttachments[0].resolveTexture = source
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = source
            pass.colorAttachments[0].storeAction = .store
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        // The piston bloom source pass reuses scene depth for occlusion.
        pass.depthAttachment.storeAction = .store
        return pass
    }

    private func encodeGrade(commandBuffer: MTLCommandBuffer, source: MTLTexture, destination: MTLTexture) {
        guard let gradePipeline else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Visualizer color grade"
        encoder.setRenderPipelineState(gradePipeline)
        encoder.setFragmentTexture(source, index: 0)
        // Match the SwiftUI backdrop in ArtworkVisualizerView, which the opaque grade covers.
        let grade = pistonSettings.grade
        let backdrop = VisualizerGrade.sRGBEncoded(pistonSettings.backgroundColor)
        gradeDitherFrame = (gradeDitherFrame + 1) % 256
        var uniforms = [
            SIMD4<Float>(backdrop, grade.saturation),
            SIMD4<Float>(grade.shadowTint, grade.amount),
            SIMD4<Float>(grade.highlightTint, grade.contrast)
        ]
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * uniforms.count, index: 0)
        encoder.setFragmentBytes(&gradeDitherFrame, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private var displayedArtworkAccent: ArtworkAccent {
        ArtworkAccent(red: Double(displayedAccent.x),
                      green: Double(displayedAccent.y),
                      blue: Double(displayedAccent.z))
    }

    private func updateAccent() {
        let target = SIMD3<Float>(Float(accent.red), Float(accent.green), Float(accent.blue))
        let now = ProcessInfo.processInfo.systemUptime
        if let start = accentTransitionStart {
            let progress = Float(min(1, max(0, (now - start) / 1.2)))
            let eased = progress * progress * (3 - 2 * progress)
            displayedAccent = accentTransitionFrom + (accentTransitionTarget - accentTransitionFrom) * eased
            if progress == 1 { accentTransitionStart = nil }
        }
        if target != accentTransitionTarget {
            // Retarget from the current color, including during an unfinished fade.
            accentTransitionFrom = displayedAccent
            accentTransitionTarget = target
            accentTransitionStart = now
        }
    }

    func draw(in view: MTKView) {
        // Pistons own their multisample attachments and resolve through the grade.
        if view.sampleCount != 1 { view.sampleCount = 1 }
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        updateAccent()
        _ = bands.withUnsafeMutableBufferPointer {
            SCSpectrumBufferRead(spectrumBuffer, $0.baseAddress, nil, nil, nil)
        }
        guard let pistonFrame = preparePistons(in: view) else { return }
        let ropeShadow = encodePistonRopeShadow(in: view, commandBuffer: commandBuffer, frame: pistonFrame)
        let frameShadow = encodePistonShadow(in: view, commandBuffer: commandBuffer,
                                            pipeline: pipelines.shadow, frame: pistonFrame)
        let reflection = encodePistonReflection(in: view, commandBuffer: commandBuffer,
                                               pipeline: pipelines.shadow, frame: pistonFrame,
                                               ropeShadow: ropeShadow)
        guard let scenePass = makeScenePass(in: view, size: drawable.texture),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) else { return }

        encoder.setRenderPipelineState(pipelines.scene)
        encoder.setFragmentTexture(fallbackTexture, index: 1)
        encoder.setFragmentTexture(reflection ?? fallbackTexture, index: 3)
        encoder.setFragmentTexture(ropeShadow ?? fallbackTexture, index: 2)
        encoder.setVertexBuffer(pistonFrame.positions, offset: 0, index: 0)
        encoder.setFragmentBuffer(pistonFrame.positions, offset: 0, index: 6)
        var uniforms = pistonFrame.uniforms
        // Fill the sky before drawing the floor and pistons.
        uniforms[3].w = 5
        uniforms.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
        }
        encoder.setDepthStencilState(glowDepthState)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setDepthStencilState(depthState)
        if let shadow = frameShadow {
            uniforms[3].w = 2
            uniforms.withUnsafeBytes { bytes in
                encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
            }
            encoder.setFragmentTexture(shadow, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        uniforms[3].w = 0
        uniforms.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
        }
        encoder.setDepthStencilState(depthState)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: pistonFrame.vertexCount)
        if pistonSettings.bloomStrength > 0 {
            uniforms[3].w = 4
            uniforms.withUnsafeBytes { bytes in
                encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
            }
            encoder.setRenderPipelineState(pipelines.glow)
            encoder.setDepthStencilState(glowDepthState)
            let solids = 32 * 12 * 3
            let ropes = pistonSettings.stringsPerPiston * PistonSimulation.segments * 6
            let bobs = pistonSettings.stringsPerPiston * 12 * 8 * 6
            for piston in 0..<PistonSimulation.count {
                encoder.drawPrimitives(type: .triangle,
                                       vertexStart: piston * (solids + ropes + bobs) + solids,
                                       vertexCount: ropes + bobs)
            }
        }
        encoder.endEncoding()
        if let depth = sceneDepth, let source = gradeSource {
            encodePistonBloom(in: view, commandBuffer: commandBuffer, frame: pistonFrame,
                              depth: depth, destination: source)
        }
        if let source = gradeSource {
            encodeGrade(commandBuffer: commandBuffer, source: source, destination: drawable.texture)
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

struct PistonCamera: Equatable {
    var yaw: Float = 0
    var pitch: Float
    var zoom: Float
    // World-space point the camera orbits and looks at.
    var target = SIMD3<Float>(0, 1, 0)

    mutating func orbit(delta: SIMD2<Float>, viewport: SIMD2<Float>,
                        pitchRange: ClosedRange<Float>) {
        // Consume each delta at tilt limits so reversing the drag responds immediately.
        let sensitivity = Float.pi / max(240, min(viewport.x, viewport.y))
        yaw = (yaw + delta.x * sensitivity).remainder(dividingBy: 2 * .pi)
        pitch = min(pitchRange.upperBound, max(pitchRange.lowerBound,
                    pitch + delta.y * sensitivity))
    }

    // Slide the target across the view plane so the scene follows the pointer.
    mutating func pan(delta: SIMD2<Float>, viewport: CGSize) {
        let view = PistonCameraProjection.camera(
            size: viewport, yaw: yaw, pitch: pitch, zoom: zoom, targetHeight: target.y)
        // The projection spans 2 / 2.1 world units per unit of distance vertically.
        let scale = 2 * view.w / (2.1 * Float(max(1, viewport.height)))
        let right = SIMD3(cos(view.y), 0, sin(view.y))
        let up = SIMD3(sin(view.z) * sin(view.y), cos(view.z), -sin(view.z) * cos(view.y))
        let moved = target + (up * delta.y - right * delta.x) * scale
        target = simd_clamp(moved, PistonCameraProjection.targetBounds.low,
                            PistonCameraProjection.targetBounds.high)
    }
}

// Camera projection and orbit limits for the Metal scene.
enum PistonCameraProjection {
    static let pitchRange: ClosedRange<Float> = -1.8...1.2
    // Start at the lowest tilt; camera(size:yaw:pitch:zoom:targetHeight:) raises it to the floor clearance.
    static let defaultCamera = PistonCamera(pitch: pitchRange.lowerBound, zoom: 0.55)

    // Keep the target above the floor and within reach of the scene.
    static let targetBounds = (low: SIMD3<Float>(-12, -1.65, -12), high: SIMD3<Float>(12, 8, 12))

    static func camera(size: CGSize, yaw: Float, pitch: Float, zoom: Float,
                       targetHeight: Float) -> SIMD4<Float> {
        let aspect = Float(size.width / max(1, size.height))
        let distance = max(13, 22 / max(0.1, aspect)) * zoom / 0.7
        // The floor is y = -1.65. Keep the camera 0.75 above it.
        let groundLimit = asin(max(-1, min(1, (-0.9 - targetHeight) / distance)))
        let viewingPitch = max(groundLimit, min(pitchRange.upperBound, max(pitchRange.lowerBound, pitch)) + 0.25)
        return SIMD4(aspect, yaw, viewingPitch, distance)
    }

    static func orbitPitchRange(size: CGSize, zoom: Float, targetHeight: Float) -> ClosedRange<Float> {
        let lowest = camera(size: size, yaw: 0, pitch: pitchRange.lowerBound, zoom: zoom,
                            targetHeight: targetHeight).z - 0.25
        return lowest...pitchRange.upperBound
    }
}
