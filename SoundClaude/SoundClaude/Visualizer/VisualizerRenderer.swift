import Foundation
import MetalKit
import MetalPerformanceShaders
import simd

enum VisualizerShader: String, CaseIterable {
    case cloth
    case pistons

    // Pistons add a 0.25-radian tilt and orbit a point above the floor.
    var cameraPitchRange: ClosedRange<Float> {
        self == .pistons ? PistonGroundControls.pitchRange : ClothCamera.pitchRange
    }

    var next: Self {
        let shaders = Self.allCases
        let index = shaders.firstIndex(of: self)!
        return shaders[(index + 1) % shaders.count]
    }

    var title: String {
        switch self {
        case .cloth: "Cloth"
        case .pistons: "Pistons"
        }
    }

    var sourceFile: String {
        switch self {
        case .cloth: "ClothVisualizer.metal"
        case .pistons: "PistonVisualizer.metal"
        }
    }

    private var functionPrefix: String {
        switch self {
        case .cloth: "clothVisualizer"
        case .pistons: "pistonVisualizer"
        }
    }

    var vertexFunction: String { functionPrefix + "Vertex" }
    var fragmentFunction: String { functionPrefix + "Fragment" }
}

final class VisualizerRenderer: NSObject, MTKViewDelegate {
    var accent: ArtworkAccent
    var shader: VisualizerShader = .cloth
    var clothSettings = ClothSettings()
    var pistonSettings = PistonSettings()
    var trackProgress: Double = 0
    var hasTrack = false
    var clothCamera = ClothCamera()

    private var shadowMask: MTLTexture?
    private var shadowBlur: MTLTexture?
    private var shadowDepth: MTLTexture?
    private var pistonRopeShadow: MTLTexture?
    private var pistonRopeShadowDepth: MTLTexture?
    private var pistonBloomMultisampleMask: MTLTexture?
    private var pistonBloomMask: MTLTexture?
    private var pistonBloomBlur: MTLTexture?
    private var pistonBloomSourcePipeline: MTLRenderPipelineState?
    private var pistonBloomCompositePipeline: MTLRenderPipelineState?
    private var pistonGlowPipeline: MTLRenderPipelineState?
    private var pistonRopeShadowPipeline: MTLRenderPipelineState?
    private var pistons = PistonSimulation()
    private var lastPistonTime: Double?
    private var cloth = ClothSimulation()
    private var bassLevel: Float = 0
    private var trebleLevel: Float = 0
    private var trebleDetector = ClothBassDetector.treble
    private var bassDetector = ClothBassDetector()
    private var lastClothTime: Double?
    private let glowDepthState: MTLDepthStencilState?
    private let depthState: MTLDepthStencilState?
    private let spectrumBuffer: OpaquePointer
    private let commandQueue: MTLCommandQueue
    private let textureLoader: MTKTextureLoader
    private let fallbackTexture: MTLTexture
    private var artworkTexture: MTLTexture?
    private var artworkImage: CGImage?
    fileprivate struct Pipelines {
        let scene: MTLRenderPipelineState
        let shadow: MTLRenderPipelineState
    }

    private let sceneSampleCount: Int
    private var pipelines: [VisualizerShader: Pipelines] = [:]
    private var bands = [Float](repeating: 0, count: Int(SCSpectrumBandCount))
#if DEBUG
    private var shaderReloaders: [VisualizerShader: VisualizerShaderReloader] = [:]
#endif

    init?(view: MTKView, spectrumBuffer: OpaquePointer, accent: ArtworkAccent) {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            return nil
        }

        sceneSampleCount = device.supportsTextureSampleCount(4) ? 4
            : (device.supportsTextureSampleCount(2) ? 2 : 1)
        do {
            for shader in VisualizerShader.allCases {
                pipelines[shader] = try Self.makePipelines(
                    device: device, library: library, pixelFormat: view.colorPixelFormat,
                    shader: shader, sampleCount: sceneSampleCount
                )
            }
            pistonGlowPipeline = try Self.makePipeline(
                device: device, library: library, pixelFormat: view.colorPixelFormat,
                shader: .pistons, sampleCount: sceneSampleCount, glowBlend: true)
            pistonBloomSourcePipeline = try Self.makePipeline(
                device: device, library: library, pixelFormat: .rgba16Float,
                shader: .pistons, sampleCount: sceneSampleCount, glowBlend: true)
            let bloom = MTLRenderPipelineDescriptor()
            bloom.label = "Piston bloom composite"
            bloom.vertexFunction = library.makeFunction(name: "pistonBloomVertex")
            bloom.fragmentFunction = library.makeFunction(name: "pistonBloomFragment")
            let attachment = bloom.colorAttachments[0]!
            attachment.pixelFormat = view.colorPixelFormat
            // Screen blend with matching alpha keeps the transparent layer premultiplied.
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceColor
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pistonBloomCompositePipeline = try device.makeRenderPipelineState(descriptor: bloom)
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
        textureLoader = MTKTextureLoader(device: device)
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
#if DEBUG
        for shader in VisualizerShader.allCases {
            shaderReloaders[shader] = VisualizerShaderReloader(
                device: device, pixelFormat: view.colorPixelFormat, shader: shader,
                sampleCount: sceneSampleCount
            )
        }
#endif
    }

    func updateArtwork(_ image: CGImage?) {
        guard artworkImage !== image else { return }
        artworkImage = image
        artworkTexture = nil
        guard let image else { return }
        // Grayscale images can load as single-channel textures, which the shader
        // reads as red. Convert to sRGB RGBA so every artwork supplies RGB.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            NSLog("[Visualizer] Cannot create artwork bitmap context")
            return
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rgbaImage = context.makeImage() else {
            NSLog("[Visualizer] Cannot create RGBA artwork image")
            return
        }
        do {
            artworkTexture = try textureLoader.newTexture(cgImage: rgbaImage, options: [
                .SRGB: false,
                .origin: MTKTextureLoader.Origin.topLeft
            ])
        } catch {
            NSLog("[Visualizer] Cannot load artwork texture: %@", String(describing: error))
        }
    }

    fileprivate static func makePipelines(
        device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat,
        shader: VisualizerShader, sampleCount: Int
    ) throws -> Pipelines {
        let scene = try makePipeline(device: device, library: library, pixelFormat: pixelFormat,
                                     shader: shader, sampleCount: sampleCount)
        // Shadow masks are blurred separately and keep single-sample attachments.
        let shadow = sampleCount == 1 ? scene : try makePipeline(
            device: device, library: library, pixelFormat: pixelFormat, shader: shader)
        return Pipelines(scene: scene, shadow: shadow)
    }

    fileprivate static func makePipeline(
        device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat,
        shader: VisualizerShader, sampleCount: Int = 1, glowBlend: Bool = false
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.rasterSampleCount = sampleCount
        descriptor.label = "Audio visualizer: \(shader.title)"
        descriptor.vertexFunction = library.makeFunction(name: shader.vertexFunction)
        descriptor.fragmentFunction = library.makeFunction(name: shader.fragmentFunction)
        guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil else {
            throw NSError(domain: "VisualizerShader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Shader must define \(shader.vertexFunction) and \(shader.fragmentFunction)."
            ])
        }
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
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
        pistons.advance(delta: lastPistonTime.map { now - $0 } ?? PistonSimulation.step, bands: bands)
        lastPistonTime = now
        var uniforms = [PistonGroundControls.camera(
            size: view.drawableSize, yaw: clothCamera.yaw,
            pitch: clothCamera.pitch, zoom: clothCamera.zoom)]
        uniforms.append(SIMD4(pistons.heights[0], pistons.heights[1], pistons.heights[2], pistons.heights[3]))
        uniforms.append(SIMD4(pistons.heights[4], pistons.heights[5], pistons.heights[6], pistons.heights[7]))
        uniforms.append(SIMD4<Float>(pistonSettings.ropeThickness * 0.5, Float(pistonSettings.stringsPerPiston), 0, 0))
        let buffer = pistons.positions.withUnsafeBytes { bytes in
            view.device?.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count)
        }
        guard let buffer else { return nil }
        // Match the floor used by the rope solver.
        uniforms[3].z = -1.65
        uniforms.append(SIMD4<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height), 0, 0))
        uniforms.append(SIMD4<Float>(pistonSettings.stripeThickness, pistonSettings.stripeFrequency,
                                     pistonSettings.headTwist * .pi / 180, pistonSettings.travel))
        uniforms.append(SIMD4<Float>(pistonSettings.stripeColor, 0))
        uniforms.append(SIMD4<Float>(pistonSettings.metalColor, 0))
        uniforms.append(SIMD4<Float>(pistonSettings.baseColor, 0))
        uniforms.append(SIMD4<Float>(pistonSettings.roughness, pistonSettings.metallic,
                                     0, 0))
        uniforms.append(SIMD4<Float>(pistonSettings.reflectionStrength, pistonSettings.edgeSoftness,
                                     pistonSettings.neutralRopeGlow, pistonSettings.bloomStrength))
        let progress = trackProgress.isFinite ? Float(min(1, max(0, trackProgress))) : 0
        let artworkAspect = artworkImage.map { Float($0.width) / Float($0.height) } ?? 1
        uniforms.append(SIMD4<Float>(progress, artworkAspect, artworkTexture == nil ? 0 : 1, hasTrack ? 1 : 0))
        return (buffer, uniforms, PistonSimulation.count *
            (32 * 12 * 3 + pistonSettings.stringsPerPiston * PistonSimulation.segments * 6))
    }

    private typealias ClothFrame = (positions: MTLBuffer, normals: MTLBuffer, uniforms: [SIMD4<Float>])

    private func prepareCloth(in view: MTKView) -> ClothFrame? {
        var clothSettings = self.clothSettings
        let artworkAspect = artworkImage.map { Float($0.width) / Float($0.height) } ?? 1
        // The size control sets the longest edge while preserving the artwork's proportions.
        let size = clothSettings.width
        clothSettings.width = size * min(1, artworkAspect)
        clothSettings.height = size / max(1, artworkAspect)
        cloth.configure(clothSettings)
        let now = ProcessInfo.processInfo.systemUptime
        let delta = lastClothTime.map { now - $0 } ?? ClothSimulation.step
        lastClothTime = now
        if let strength = bassDetector.update(level: bassLevel, delta: delta) {
            cloth.impulse(strength: strength)
        }
        if let strength = trebleDetector.update(level: trebleLevel, delta: delta) {
            cloth.trebleImpulse(strength: strength)
        }
        cloth.advance(delta: delta)
        // Each command owns its snapshot until the GPU completes the frame.
        let buffer = (cloth.positions + cloth.attachments).withUnsafeBytes { bytes in
            view.device?.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count)
        }
        // Precompute unit normals once per grid node for bicubic fragment sampling.
        let columns = cloth.columns, rows = cloth.rows
        let normals: [SIMD4<Float>] = cloth.positions.indices.map { index in
            let x = index % columns, y = index / columns
            let tangent = cloth.positions[y * columns + min(x + 1, columns - 1)]
                - cloth.positions[y * columns + max(x - 1, 0)]
            let bitangent = cloth.positions[min(y + 1, rows - 1) * columns + x]
                - cloth.positions[max(y - 1, 0) * columns + x]
            let cross = simd_cross(SIMD3(bitangent.x, bitangent.y, bitangent.z),
                                   SIMD3(tangent.x, tangent.y, tangent.z))
            let length = simd_length(cross)
            let normal = length > 0.00001 ? cross / length : SIMD3<Float>(0, 0, 1)
            return SIMD4(normal.x, normal.y, normal.z, 0)
        }
        let normalBuffer = normals.withUnsafeBytes { bytes in
            view.device?.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count)
        }
        if let buffer, let normalBuffer {
            let camera = ClothGroundControls.camera(size: view.drawableSize, camera: clothCamera,
                                                     artworkAspect: artworkAspect)
            let bassHighlight = cloth.bassPulse * cloth.bassPulse * cloth.bassPulse
                * (0.8 + 1.2 * cloth.bassPulseLevel)
            // Strong bass hits triple the selected shine, then fade back to it.
            let shineIntensity = clothSettings.shineIntensity * (1 + bassHighlight)
            // Six float4s, matching ClothUniforms in Metal.
            let uniforms = [
                SIMD4<Float>(Float(cloth.columns), Float(cloth.rows), clothSettings.width, clothSettings.height),
                camera,
                SIMD4<Float>(shineIntensity, 0, clothSettings.showMesh ? 1 : 0, 0),
                SIMD4<Float>(Float(view.drawableSize.width), 0.48, ClothSimulation.groundDepth, Float(view.drawableSize.height)),
                SIMD4<Float>(trackProgress.isFinite ? Float(min(1, max(0, trackProgress))) : 0, hasTrack ? 1 : 0, 0, 0),
                SIMD4<Float>(cloth.bassOrigin.x, cloth.bassOrigin.y, clothSettings.impulseRadius,
                             bassHighlight * clothSettings.flashBrightness)
            ]
            return (buffer, normalBuffer, uniforms)
        }
        return nil
    }

    private func encodeClothShadow(
        in view: MTKView, commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState, frame: ClothFrame
    ) -> MTLTexture? {
        encodeShadow(in: view, commandBuffer: commandBuffer) { encoder in
            encoder.setRenderPipelineState(pipeline)
            var accentColor = SIMD4<Float>(Float(accent.red), Float(accent.green), Float(accent.blue), 0)
            encoder.setFragmentBytes(&accentColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            encoder.setVertexBuffer(frame.positions, offset: 0, index: 0)
            encoder.setFragmentBuffer(frame.normals, offset: 0, index: 5)
            encoder.setFragmentBuffer(frame.positions, offset: 0, index: 6)
            encoder.setFragmentTexture(fallbackTexture, index: 1)
            encoder.setFragmentTexture(artworkTexture ?? fallbackTexture, index: 0)
            var uniforms = frame.uniforms
            uniforms[2].w = 1
            uniforms.withUnsafeBytes { bytes in
                encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
            }
            // Opaque writes form one silhouette, including where cloth folds overlap.
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: (cloth.columns - 1) * (cloth.rows - 1) * 6)
            uniforms[2].w = 4
            uniforms.withUnsafeBytes { bytes in
                encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
            }
            // Merge poles, feet and ropes into the mask; exclude the ground plane.
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 4 * 3 * 12 * 12)
        }
    }

    private func encodePistonRopeShadow(
        in view: MTKView, commandBuffer: MTLCommandBuffer, frame: PistonFrame
    ) -> MTLTexture? {
        guard let device = view.device else { return nil }
        if pistonRopeShadowPipeline == nil, let library = device.makeDefaultLibrary() {
            pistonRopeShadowPipeline = try? Self.makePipeline(
                device: device, library: library, pixelFormat: .rgba16Float, shader: .pistons)
        }
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
        guard let texture = pistonRopeShadow, let depth = pistonRopeShadowDepth,
              let pipeline = pistonRopeShadowPipeline else { return nil }
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
        encoder.setFragmentTexture(fallbackTexture, index: 0)
        encoder.setFragmentTexture(fallbackTexture, index: 2)
        var uniforms = frame.uniforms
        uniforms[3].w = 3
        uniforms.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
        }
        let solids = 32 * 12 * 3
        let ropes = pistonSettings.stringsPerPiston * PistonSimulation.segments * 6
        for piston in 0..<PistonSimulation.count {
            encoder.drawPrimitives(type: .triangle,
                                   vertexStart: piston * (solids + ropes) + solids - 32 * 12,
                                   vertexCount: ropes + 32 * 12)
        }
        encoder.endEncoding()
        return texture
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
            encoder.setFragmentTexture(fallbackTexture, index: 0)
            encoder.setFragmentTexture(fallbackTexture, index: 2)
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
        // Bound the offscreen cost and keep softness proportional to the viewport.
        let scale = min(1, 512 / max(1, max(view.drawableSize.width, view.drawableSize.height)))
        let width = max(1, Int(view.drawableSize.width * scale))
        let height = max(1, Int(view.drawableSize.height * scale))
        if shadowMask?.width != width || shadowMask?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: view.colorPixelFormat, width: width, height: height, mipmapped: false
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
        let blur = MPSImageGaussianBlur(device: device, sigma: max(1, Float(min(width, height)) * (shader == .cloth ? 0.003 : 0.008)))
        blur.edgeMode = .zero
        blur.encode(commandBuffer: commandBuffer, sourceTexture: shadowMask, destinationTexture: shadowBlur)
        return shadowBlur
    }

    private func encodePistonBloom(
        in view: MTKView, commandBuffer: MTLCommandBuffer, frame: PistonFrame,
        depth: MTLTexture, destination: MTLTexture
    ) {
        guard pistonSettings.bloomStrength > 0 else { return }
        guard let device = view.device, let sourcePipeline = pistonBloomSourcePipeline,
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
        source.setRenderPipelineState(sourcePipeline)
        source.setDepthStencilState(glowDepthState)
        source.setVertexBuffer(frame.positions, offset: 0, index: 0)
        source.setFragmentBuffer(frame.positions, offset: 0, index: 6)
        source.setFragmentTexture(fallbackTexture, index: 1)
        source.setFragmentTexture(fallbackTexture, index: 0)
        source.setFragmentTexture(fallbackTexture, index: 2)
        var uniforms = frame.uniforms
        uniforms[3].w = 4
        uniforms.withUnsafeBytes { bytes in
            source.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            source.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
        }
        let solids = 32 * 12 * 3
        let ropes = pistonSettings.stringsPerPiston * PistonSimulation.segments * 6
        for piston in 0..<PistonSimulation.count {
            source.drawPrimitives(type: .triangle,
                                  vertexStart: piston * (solids + ropes) + solids, vertexCount: ropes)
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
#if DEBUG
        for (shader, reloader) in shaderReloaders {
            if let replacement = reloader.takePipeline() {
                pipelines[shader] = replacement
            }
        }
#endif
        // MTKView creates matching multisample color/depth attachments and resolves
        // the scene into the drawable before the single-sample bloom composite.
        if view.sampleCount != sceneSampleCount { view.sampleCount = sceneSampleCount }
        guard let pipelines = pipelines[shader],
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        var rms: Float = 0
        _ = bands.withUnsafeMutableBufferPointer {
            SCSpectrumBufferRead(spectrumBuffer, $0.baseAddress, &rms, &bassLevel, &trebleLevel)
        }
        let clothFrame = shader == .cloth
            ? prepareCloth(in: view) : nil
        let pistonFrame = shader == .pistons ? preparePistons(in: view) : nil
        let ropeShadow = pistonFrame.flatMap {
            encodePistonRopeShadow(in: view, commandBuffer: commandBuffer, frame: $0)
        }
        let frameShadow = clothFrame.flatMap {
            encodeClothShadow(in: view, commandBuffer: commandBuffer,
                              pipeline: pipelines.shadow, frame: $0)
        } ?? pistonFrame.flatMap {
            encodePistonShadow(in: view, commandBuffer: commandBuffer,
                               pipeline: pipelines.shadow, frame: $0)
        }
        if pistonFrame != nil {
            renderPassDescriptor.depthAttachment.storeAction = .store
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPassDescriptor
              ) else {
            return
        }

        encoder.setRenderPipelineState(pipelines.scene)
        encoder.setFragmentTexture(fallbackTexture, index: 1)
        encoder.setFragmentTexture(artworkTexture ?? fallbackTexture, index: 0)
        var accentColor = SIMD4<Float>(
            Float(accent.red), Float(accent.green), Float(accent.blue),
            artworkTexture == nil ? 0 : 1
        )
        encoder.setFragmentBytes(
            &accentColor,
            length: MemoryLayout<SIMD4<Float>>.stride,
            index: 2
        )
        if shader != .cloth {
            lastClothTime = nil
            bassDetector = ClothBassDetector()
            trebleDetector = .treble
        }
        if shader != .pistons { lastPistonTime = nil }
        if shader == .pistons {
            if let frame = pistonFrame {
                encoder.setFragmentTexture(ropeShadow ?? fallbackTexture, index: 2)
                encoder.setVertexBuffer(frame.positions, offset: 0, index: 0)
                encoder.setFragmentBuffer(frame.positions, offset: 0, index: 6)
                var uniforms = frame.uniforms
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
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: frame.vertexCount)
                if pistonSettings.bloomStrength > 0, let glowPipeline = pistonGlowPipeline {
                    uniforms[3].w = 4
                    uniforms.withUnsafeBytes { bytes in
                        encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
                        encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
                    }
                    encoder.setRenderPipelineState(glowPipeline)
                    encoder.setDepthStencilState(glowDepthState)
                    let solids = 32 * 12 * 3
                    let ropes = pistonSettings.stringsPerPiston * PistonSimulation.segments * 6
                    for piston in 0..<PistonSimulation.count {
                        encoder.drawPrimitives(type: .triangle,
                                               vertexStart: piston * (solids + ropes) + solids,
                                               vertexCount: ropes)
                    }
                }
            }
        } else if shader == .cloth {
            if let frame = clothFrame {
                var uniforms = frame.uniforms
                encoder.setVertexBuffer(frame.positions, offset: 0, index: 0)
                encoder.setFragmentBuffer(frame.normals, offset: 0, index: 5)
                encoder.setFragmentBuffer(frame.positions, offset: 0, index: 6)
                encoder.setFragmentTexture(frameShadow ?? fallbackTexture, index: 1)
                if frameShadow == nil { uniforms[3].y = 0 }
                uniforms[2].w = 2
                uniforms.withUnsafeBytes { bytes in
                    encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
                    encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
                }
                encoder.setDepthStencilState(depthState)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                uniforms[2].w = 0
                uniforms.withUnsafeBytes { bytes in
                    encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
                    encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
                }
                encoder.setDepthStencilState(depthState)
                encoder.setFrontFacing(.counterClockwise)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: (cloth.columns - 1) * (cloth.rows - 1) * 6)
                uniforms[2].w = 3
                uniforms.withUnsafeBytes { bytes in
                    encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
                    encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
                }
                // Four supports, each with a pillar, foot and rope.
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 4 * 3 * 12 * 12)
            }
        }
        encoder.endEncoding()
        if let frame = pistonFrame, let depth = renderPassDescriptor.depthAttachment.texture {
            encodePistonBloom(in: view, commandBuffer: commandBuffer, frame: frame,
                              depth: depth, destination: drawable.texture)
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

#if DEBUG
/// Polls file contents to handle both in-place writes and atomic editor saves.
private final class VisualizerShaderReloader {
    private let device: MTLDevice
    private let pixelFormat: MTLPixelFormat
    private let shader: VisualizerShader
    private let sourceURL: URL
    private let timer: DispatchSourceTimer
    private var lastSource: String?
    private var lastReadError: String?
    private let lock = NSLock()
    private var pendingPipeline: VisualizerRenderer.Pipelines?
    private let sampleCount: Int

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, shader: VisualizerShader, sampleCount: Int) {
        self.sampleCount = sampleCount
        self.shader = shader
        sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shaders/\(shader.sourceFile)")
        self.device = device
        self.pixelFormat = pixelFormat
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(
            label: "SoundClaude.shaderReload", qos: .utility
        ))
        timer.schedule(deadline: .now(), repeating: .milliseconds(300))
        timer.setEventHandler { [weak self] in self?.reloadIfChanged() }
        timer.resume()
        NSLog("[Visualizer] Watching %@", sourceURL.path)
    }

    deinit { timer.cancel() }

    func takePipeline() -> VisualizerRenderer.Pipelines? {
        lock.lock()
        defer { lock.unlock() }
        let pipeline = pendingPipeline
        pendingPipeline = nil
        return pipeline
    }

    private func reloadIfChanged() {
        let source: String
        do {
            source = try String(contentsOf: sourceURL, encoding: .utf8)
            lastReadError = nil
        } catch {
            let message = error.localizedDescription
            if message != lastReadError {
                NSLog("[Visualizer] Cannot read shader: %@", message)
                lastReadError = message
            }
            return
        }
        guard source != lastSource else { return }
        lastSource = source
        do {
            // Compile off the render thread. Publish only a complete, valid pipeline.
            let library = try device.makeLibrary(source: source, options: nil)
            let pipeline = try VisualizerRenderer.makePipelines(
                device: device, library: library, pixelFormat: pixelFormat, shader: shader,
                sampleCount: sampleCount
            )
            lock.lock()
            pendingPipeline = pipeline
            lock.unlock()
            NSLog("[Visualizer] Shader reloaded")
        } catch {
            NSLog("[Visualizer] Shader reload failed; keeping last working shader: %@",
                  String(describing: error))
        }
    }
}
#endif

// Shared camera projection keeps ground controls aligned with the Metal scene.
enum PistonGroundControls {
    static let pitchRange: ClosedRange<Float> = -0.25...1.2
    static let defaultCamera = ClothCamera(pitch: pitchRange.lowerBound, zoom: 0.6)

    enum Hit {
        case previous
        case next
        case seek(Double)
    }

    static func camera(size: CGSize, yaw: Float, pitch: Float, zoom: Float) -> SIMD4<Float> {
        let aspect = Float(size.width / max(1, size.height))
        let distance = max(13, 17 / max(0.1, aspect)) * zoom / 0.7
        return SIMD4(aspect, yaw, min(pitchRange.upperBound, max(pitchRange.lowerBound, pitch)) + 0.25, distance)
    }

    // Input points use SwiftUI's top-left origin. Intersect the view ray with
    // the same world-space floor used in PistonVisualizer.metal.
    static func hit(at point: CGPoint, size: CGSize, camera: SIMD4<Float>) -> Hit? {
        guard size.width > 0, size.height > 0,
              point.x >= 0, point.x <= size.width, point.y >= 0, point.y <= size.height else { return nil }
        let ndc = SIMD2<Float>(Float(point.x / size.width) * 2 - 1,
                               1 - Float(point.y / size.height) * 2)
        func inverseRotate(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let q = SIMD3(p.x, cos(camera.z) * p.y + sin(camera.z) * p.z,
                          -sin(camera.z) * p.y + cos(camera.z) * p.z)
            return SIMD3(cos(camera.y) * q.x - sin(camera.y) * q.z, q.y,
                         sin(camera.y) * q.x + cos(camera.y) * q.z)
        }
        let origin = inverseRotate(SIMD3(0, 0, camera.w))
        let ray = inverseRotate(SIMD3(ndc.x * camera.x / 2.1, ndc.y / 2.1, -1))
        guard abs(ray.y) > 0.000001 else { return nil }
        let distance = (-2.65 - origin.y) / ray.y
        guard distance >= 0.1, distance < 100 else { return nil }
        let floor = origin + ray * distance
        // Match the circular projected buttons centered beside the artwork.
        for direction in [-1, 1] {
            let offset = SIMD2(floor.x - Float(direction) * 2.15, floor.z - 3.4)
            if simd_length_squared(offset) <= 0.4 * 0.4 {
                return direction < 0 ? .previous : .next
            }
        }
        // Match the rail at the near edge of the artwork, with extra click
        // tolerance around its thin stroke. Clamp clicks at the rounded ends.
        let rail = SIMD2(floor.x + 1.6, floor.z - 5.25)
        let offset = SIMD2(rail.x - min(3.15, max(0.05, rail.x)), rail.y)
        if simd_length_squared(offset) <= 0.15 * 0.15 {
            return .seek(Double(min(1, max(0, rail.x / 3.2))))
        }
        return nil
    }
}

// Z-up projection and floor hit targets for the cloth's playback controls.
enum ClothGroundControls {
    static func camera(size: CGSize, camera: ClothCamera, artworkAspect: Float) -> SIMD4<Float> {
        let reference = ClothSettings().width
        let width = reference * min(1, artworkAspect) + 3.4
        let height = reference / max(1, artworkAspect) + 3.4
        let distance = sqrt(width * width + height * height) * 1.35 * camera.zoom
        return SIMD4(Float(size.width / max(1, size.height)), camera.yaw,
                     camera.viewingPitch(distance: distance), distance)
    }

    static func hit(at point: CGPoint, size: CGSize, camera: SIMD4<Float>,
                    height: Float) -> PistonGroundControls.Hit? {
        guard size.width > 0, size.height > 0,
              point.x >= 0, point.x <= size.width, point.y >= 0, point.y <= size.height else { return nil }
        let ndc = SIMD2<Float>(Float(point.x / size.width) * 2 - 1,
                               1 - Float(point.y / size.height) * 2)
        func inverseRotate(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let q = SIMD3(p.x, cos(camera.z) * p.y - sin(camera.z) * p.z,
                          sin(camera.z) * p.y + cos(camera.z) * p.z)
            return SIMD3(cos(camera.y) * q.x + sin(camera.y) * q.y,
                         -sin(camera.y) * q.x + cos(camera.y) * q.y, q.z)
        }
        let scale = min(2.6, 2.6 * camera.x)
        let origin = inverseRotate(SIMD3(0, 0, camera.w))
        let ray = inverseRotate(SIMD3(ndc.x * camera.x / scale, ndc.y / scale, -1))
        guard abs(ray.z) > 0.000001 else { return nil }
        let distance = (ClothSimulation.groundDepth - origin.z) / ray.z
        guard distance >= 0.1, distance < 100 else { return nil }
        let floor = origin + ray * distance
        let local = SIMD2(floor.x, floor.y + height * 0.5 + 1.8)
        for direction in [-1, 1] {
            if simd_length_squared(local - SIMD2(Float(direction) * 4, 0)) <= 0.55 * 0.55 {
                return direction < 0 ? .previous : .next
            }
        }
        let offset = SIMD2(local.x - min(3, max(-3, local.x)), local.y)
        if simd_length_squared(offset) <= 0.2 * 0.2 {
            return .seek(Double(min(1, max(0, (local.x + 3) / 6))))
        }
        return nil
    }
}
