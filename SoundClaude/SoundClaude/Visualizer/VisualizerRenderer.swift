import Foundation
import MetalKit
import MetalPerformanceShaders
import simd

enum VisualizerShader: String, CaseIterable {
    case pistons
    case fluid

    var next: Self {
        let shaders = Self.allCases
        let index = shaders.firstIndex(of: self)!
        return shaders[(index + 1) % shaders.count]
    }

    var title: String {
        switch self {
        case .pistons: "Pistons"
        case .fluid: "Fluid"
        }
    }

    var sourceFile: String {
        switch self {
        case .pistons: "PistonVisualizer.metal"
        case .fluid: "FluidVisualizer.metal"
        }
    }

    private var functionPrefix: String {
        switch self {
        case .pistons: "pistonVisualizer"
        case .fluid: "fluidVisualizer"
        }
    }

    var vertexFunction: String { functionPrefix + "Vertex" }
    var fragmentFunction: String { functionPrefix + "Fragment" }

    // Pistons render at half-float precision for the final grade.
    func pixelFormat(drawable: MTLPixelFormat) -> MTLPixelFormat {
        self == .pistons ? .rgba16Float : drawable
    }
}

final class VisualizerRenderer: NSObject, MTKViewDelegate {
    var accent: ArtworkAccent
    private var displayedAccent: SIMD3<Float>
    private var accentTransitionFrom: SIMD3<Float>
    private var accentTransitionTarget: SIMD3<Float>
    private var accentTransitionStart: Double?
    var shader: VisualizerShader = .pistons
    var fluidSettings = FluidSettings()
    var fluidTouch = FluidTouch()
    private var fluid: FluidSimulation?
    var pistonSettings = PistonSettings()
    var trackProgress: Double = 0
    var hasTrack = false
    var isPlaying = false
    var pistonCamera = PistonGroundControls.defaultCamera

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
    private var gradeSource: MTLTexture?
    private var gradeMultisample: MTLTexture?
    private var sceneDepth: MTLTexture?
    private var gradePipeline: MTLRenderPipelineState?
    private var gradeFrame: UInt32 = 0
    private var pistons = PistonSimulation()
    private var lastPistonTime: Double?
    private let glowDepthState: MTLDepthStencilState?
    private let depthState: MTLDepthStencilState?
    private let spectrumBuffer: OpaquePointer
    private let commandQueue: MTLCommandQueue
    private var artworkTask: Task<MTLTexture?, Never>?
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
            fluid = try FluidSimulation(device: device, library: library)
            for shader in VisualizerShader.allCases {
                pipelines[shader] = try Self.makePipelines(
                    device: device, library: library,
                    pixelFormat: shader.pixelFormat(drawable: view.colorPixelFormat),
                    shader: shader, sampleCount: shader == .fluid ? 1 : sceneSampleCount
                )
            }
            pistonGlowPipeline = try Self.makePipeline(
                device: device, library: library, pixelFormat: .rgba16Float,
                shader: .pistons, sampleCount: sceneSampleCount, glowBlend: true)
            pistonBloomSourcePipeline = try Self.makePipeline(
                device: device, library: library, pixelFormat: .rgba16Float,
                shader: .pistons, sampleCount: sceneSampleCount, glowBlend: true)
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
#if DEBUG
        for shader in VisualizerShader.allCases {
            shaderReloaders[shader] = VisualizerShaderReloader(
                device: device, pixelFormat: shader.pixelFormat(drawable: view.colorPixelFormat), shader: shader,
                sampleCount: shader == .fluid ? 1 : sceneSampleCount
            )
        }
#endif
    }

    func updateArtwork(_ image: CGImage?) {
        guard artworkImage !== image else { return }
        artworkTask?.cancel()
        artworkTask = nil
        artworkImage = image
        artworkTexture = nil
        guard let image else { return }
        let device = commandQueue.device
        let task = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil as MTLTexture? }
            return Self.makeArtworkTexture(image, device: device)
        }
        artworkTask = task
        Task { @MainActor [weak self] in
            let texture = await task.value
            guard let self, !task.isCancelled, artworkImage === image else { return }
            artworkTexture = texture
            artworkTask = nil
        }
    }

    deinit { artworkTask?.cancel() }

    private static func makeArtworkTexture(_ image: CGImage, device: MTLDevice) -> MTLTexture? {
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
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rgbaImage = context.makeImage() else {
            NSLog("[Visualizer] Cannot create RGBA artwork image")
            return nil
        }
        do {
            guard !Task.isCancelled else { return nil }
            return try MTKTextureLoader(device: device).newTexture(cgImage: rgbaImage, options: [
                .SRGB: false,
                .origin: MTKTextureLoader.Origin.topLeft
            ])
        } catch {
            NSLog("[Visualizer] Cannot load artwork texture: %@", String(describing: error))
            return nil
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
        let delta = lastPistonTime.map { now - $0 } ?? PistonSimulation.step
        pistons.advance(delta: delta, bands: bands)
        lastPistonTime = now
        var uniforms = [PistonGroundControls.camera(
            size: view.drawableSize, yaw: pistonCamera.yaw,
            pitch: pistonCamera.pitch, zoom: pistonCamera.zoom)]
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
        uniforms.append(SIMD4<Float>(pistonSettings.metalColor, 0))
        uniforms.append(SIMD4<Float>(pistonSettings.baseColor, 0))
        uniforms.append(SIMD4<Float>(pistonSettings.roughness, pistonSettings.metallic,
                                     pistonSettings.spotlightStrength, pistonSettings.spotlightSize))
        uniforms.append(SIMD4<Float>(pistonSettings.reflectionStrength, pistonSettings.edgeSoftness,
                                     pistonSettings.neutralRopeGlow, pistonSettings.bloomStrength))
        let progress = trackProgress.isFinite ? Float(min(1, max(0, trackProgress))) : 0
        let artworkAspect = artworkImage.map { Float($0.width) / Float($0.height) } ?? 1
        let showsGroundControls = hasTrack && pistonSettings.showsGroundControls
        uniforms.append(SIMD4<Float>(progress, artworkAspect, artworkTexture == nil ? 0 : 1, showsGroundControls ? 1 : 0))
        uniforms.append(SIMD4<Float>(pistonSettings.groundColor, 0))
        uniforms.append(SIMD4<Float>(pistonSettings.spotlightColor(for: displayedArtworkAccent), 0))
        uniforms.append(SIMD4<Float>(pistonSettings.lightColor(for: displayedArtworkAccent), 0))
        uniforms.append(SIMD4<Float>(pistonSettings.groundHighlightStrength, pistonSettings.groundHighlightSoftness,
                                     pistonSettings.groundFogStart, pistonSettings.groundFogDensity))
        uniforms.append(SIMD4<Float>(VisualizerGrade.sRGBEncoded(pistonSettings.backgroundColor), 0))
        uniforms.append(SIMD4<Float>(pistonSettings.lightDirection, 0))
        return (buffer, uniforms, PistonSimulation.count *
            (32 * 12 * 3 + pistonSettings.stringsPerPiston * (PistonSimulation.segments * 6 + 12 * 8 * 6)))
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
        let bobs = pistonSettings.stringsPerPiston * 12 * 8 * 6
        for piston in 0..<PistonSimulation.count {
            encoder.drawPrimitives(type: .triangle,
                                   vertexStart: piston * (solids + ropes + bobs) + solids - 32 * 12,
                                   vertexCount: ropes + bobs + 32 * 12)
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
        // Cap offscreen cost and keep blur softness proportional to the viewport.
        let maximumDimension: CGFloat = 512
        let scale = min(1, maximumDimension / max(1, max(view.drawableSize.width, view.drawableSize.height)))
        let width = max(1, Int(view.drawableSize.width * scale))
        let height = max(1, Int(view.drawableSize.height * scale))
        let pixelFormat = shader.pixelFormat(drawable: view.colorPixelFormat)
        if shadowMask?.width != width || shadowMask?.height != height || shadowMask?.pixelFormat != pixelFormat {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
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
        // A plain backdrop keeps the scene lighting without a background gradient.
        let glow = SIMD3<Float>.zero
        let glowRadius: Float = 0
        gradeFrame = (gradeFrame + 1) % 256
        var uniforms = [
            SIMD4<Float>(Float(destination.width), Float(destination.height), glowRadius, Float(gradeFrame)),
            SIMD4<Float>(backdrop, 0),
            SIMD4<Float>(glow, 0),
            SIMD4<Float>(grade.amount, grade.contrast, grade.saturation, grade.vignette),
            SIMD4<Float>(grade.shadowTint, grade.grain),
            SIMD4<Float>(grade.highlightTint, 0)
        ]
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * uniforms.count, index: 0)
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
        guard shader == .pistons else {
            displayedAccent = target
            accentTransitionTarget = target
            accentTransitionStart = nil
            return
        }
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
#if DEBUG
        for (shader, reloader) in shaderReloaders {
            if let replacement = reloader.takePipeline() {
                pipelines[shader] = replacement
            }
        }
#endif
        // Pistons own their multisample attachments and resolve through the grade.
        if view.sampleCount != 1 { view.sampleCount = 1 }
        guard let pipelines = pipelines[shader],
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        updateAccent()
        _ = bands.withUnsafeMutableBufferPointer {
            SCSpectrumBufferRead(spectrumBuffer, $0.baseAddress, nil, nil, nil)
        }
        if shader == .fluid {
            lastPistonTime = nil
            if let texture = fluid?.encode(commandBuffer: commandBuffer, size: view.drawableSize,
                    settings: fluidSettings, bands: bands,
                    touch: fluidTouch),
               let effects = fluid?.encodeEffects(commandBuffer: commandBuffer, dye: texture,
                    size: view.drawableSize, settings: fluidSettings),
               let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                encoder.setRenderPipelineState(pipelines.scene)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentTexture(effects.bloom, index: 1)
                encoder.setFragmentTexture(effects.rays, index: 2)
                var display = FluidDisplayUniforms(size: view.drawableSize, settings: fluidSettings,
                                                  emitterPositions: fluid?.emitterPositions ?? .zero,
                                                  middleEmitterY: fluid?.middleEmitterY ?? 0.5)
                encoder.setFragmentBytes(&display, length: MemoryLayout<FluidDisplayUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        fluid?.suspend()
        let pistonFrame = shader == .pistons ? preparePistons(in: view) : nil
        let ropeShadow = pistonFrame.flatMap {
            encodePistonRopeShadow(in: view, commandBuffer: commandBuffer, frame: $0)
        }
        let frameShadow = pistonFrame.flatMap {
            encodePistonShadow(in: view, commandBuffer: commandBuffer,
                               pipeline: pipelines.shadow, frame: $0)
        }
        guard let scenePass = pistonFrame == nil
                ? renderPassDescriptor : makeScenePass(in: view, size: drawable.texture),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) else {
            return
        }

        encoder.setRenderPipelineState(pipelines.scene)
        encoder.setFragmentTexture(fallbackTexture, index: 1)
        encoder.setFragmentTexture(artworkTexture ?? fallbackTexture, index: 0)
        var accentColor = SIMD4<Float>(
            displayedAccent,
            artworkTexture == nil ? 0 : 1
        )
        encoder.setFragmentBytes(
            &accentColor,
            length: MemoryLayout<SIMD4<Float>>.stride,
            index: 2
        )
        if shader != .pistons { lastPistonTime = nil }
        if shader == .pistons {
            if let frame = pistonFrame {
                encoder.setFragmentTexture(ropeShadow ?? fallbackTexture, index: 2)
                encoder.setVertexBuffer(frame.positions, offset: 0, index: 0)
                encoder.setFragmentBuffer(frame.positions, offset: 0, index: 6)
                var uniforms = frame.uniforms
                // Fill the sky first. Surface passes integrate the same shafts only
                // up to their own depth, preserving floor and piston occlusion.
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
                    let bobs = pistonSettings.stringsPerPiston * 12 * 8 * 6
                    for piston in 0..<PistonSimulation.count {
                        encoder.drawPrimitives(type: .triangle,
                                               vertexStart: piston * (solids + ropes + bobs) + solids,
                                               vertexCount: ropes + bobs)
                    }
                }

            }
        }
        encoder.endEncoding()
        if let frame = pistonFrame, let depth = sceneDepth, let source = gradeSource {
            encodePistonBloom(in: view, commandBuffer: commandBuffer, frame: frame,
                              depth: depth, destination: source)
        }
        if pistonFrame != nil, let source = gradeSource {
            encodeGrade(commandBuffer: commandBuffer, source: source, destination: drawable.texture)
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

struct PistonCamera: Equatable {
    var yaw: Float = 0
    var pitch: Float
    var zoom: Float

    mutating func orbit(delta: SIMD2<Float>, viewport: SIMD2<Float>,
                        pitchRange: ClosedRange<Float>) {
        // Consume each delta at tilt limits so reversing the drag responds immediately.
        let sensitivity = Float.pi / max(240, min(viewport.x, viewport.y))
        yaw = (yaw + delta.x * sensitivity).remainder(dividingBy: 2 * .pi)
        pitch = min(pitchRange.upperBound, max(pitchRange.lowerBound,
                    pitch + delta.y * sensitivity))
    }
}

// Shared camera projection keeps ground controls aligned with the Metal scene.
enum PistonGroundControls {
    static let pitchRange: ClosedRange<Float> = -1.8...1.2
    // Start at the lowest tilt; camera(size:yaw:pitch:zoom:) raises it to the floor clearance.
    static let defaultCamera = PistonCamera(pitch: pitchRange.lowerBound, zoom: 0.55)
    // Floor position and scale of the artwork, rail and buttons layout.
    static let layoutCenter = SIMD2<Float>(0, 3.4)
    static let layoutScale: Float = 0.7

    enum Hit {
        case playPause
        case previous
        case next
        case seek(Double)
    }

    static func camera(size: CGSize, yaw: Float, pitch: Float, zoom: Float) -> SIMD4<Float> {
        let aspect = Float(size.width / max(1, size.height))
        let distance = max(13, 17 / max(0.1, aspect)) * zoom / 0.7
        // Orbit around y = 1; the floor is y = -1.65. Keep 0.75 clearance.
        let groundLimit = asin(max(-1, min(1, -1.9 / distance)))
        let viewingPitch = max(groundLimit, min(pitchRange.upperBound, max(pitchRange.lowerBound, pitch)) + 0.25)
        return SIMD4(aspect, yaw, viewingPitch, distance)
    }

    static func orbitPitchRange(size: CGSize, zoom: Float) -> ClosedRange<Float> {
        let lowest = camera(size: size, yaw: 0, pitch: pitchRange.lowerBound, zoom: zoom).z - 0.25
        return lowest...pitchRange.upperBound
    }

    // Input points use SwiftUI's top-left origin. Intersect the view ray with
    // the same world-space floor used in PistonVisualizer.metal.
    static func hit(at point: CGPoint, size: CGSize, camera: SIMD4<Float>, artworkAspect: Float = 1) -> Hit? {
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
        let local = (SIMD2(floor.x, floor.z) - layoutCenter) / layoutScale
        // Match the aspect-fitted artwork projection in PistonVisualizer.metal.
        let fit = SIMD2(min(artworkAspect, 1), min(1 / max(artworkAspect, 0.001), 1))
        if abs(local.x) <= 1.6 * fit.x, abs(local.y) <= 1.6 * fit.y {
            return .playPause
        }
        // Match the circular projected buttons centered beside the artwork.
        for direction in [-1, 1] {
            let offset = SIMD2(local.x - Float(direction) * 2.15, local.y)
            if simd_length_squared(offset) <= 0.4 * 0.4 {
                return direction < 0 ? .previous : .next
            }
        }
        // Match the rail at the near edge of the artwork, with extra click
        // tolerance around its thin stroke. Clamp clicks at the rounded ends.
        let rail = SIMD2(local.x + 1.6, local.y - 1.85)
        let offset = SIMD2(rail.x - min(3.15, max(0.05, rail.x)), rail.y)
        let tolerance = 0.15 / layoutScale // Keep the click target from shrinking with the layout.
        if simd_length_squared(offset) <= tolerance * tolerance {
            return .seek(Double(min(1, max(0, rail.x / 3.2))))
        }
        return nil
    }
}
