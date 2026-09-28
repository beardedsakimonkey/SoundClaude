import Foundation
import MetalKit
import MetalPerformanceShaders
import simd

enum VisualizerShader: String, CaseIterable {
    case bars
    case cloth
    case pistons

    var isSpatial: Bool { self == .cloth || self == .pistons }

    // Pistons add a 0.25-radian tilt and orbit a point above the floor.
    var cameraPitchRange: ClosedRange<Float> {
        self == .pistons ? -0.25...1.2 : -1.45...1.45
    }

    var next: Self {
        let shaders = Self.allCases
        let index = shaders.firstIndex(of: self)!
        return shaders[(index + 1) % shaders.count]
    }

    var title: String {
        switch self {
        case .bars: "Bars"
        case .cloth: "Cloth"
        case .pistons: "Pistons"
        }
    }

    var sourceFile: String {
        switch self {
        case .bars: "AudioVisualizer.metal"
        case .cloth: "ClothVisualizer.metal"
        case .pistons: "PistonVisualizer.metal"
        }
    }

    private var functionPrefix: String {
        switch self {
        case .bars: "visualizer"
        case .cloth: "clothVisualizer"
        case .pistons: "pistonVisualizer"
        }
    }

    var vertexFunction: String { functionPrefix + "Vertex" }
    var fragmentFunction: String { functionPrefix + "Fragment" }
}

final class VisualizerRenderer: NSObject, MTKViewDelegate {
    var accent: ArtworkAccent
    var shader: VisualizerShader = .bars
    var clothSettings = ClothSettings()
    var pistonSettings = PistonSettings()
    var clothCamera = ClothCamera()

    private var shadowMask: MTLTexture?
    private var shadowBlur: MTLTexture?
    private var shadowDepth: MTLTexture?
    private var pistonRopeShadow: MTLTexture?
    private var pistonRopeShadowDepth: MTLTexture?
    private var pistonRopeShadowPipeline: MTLRenderPipelineState?
    private var pistons = PistonSimulation()
    private var lastPistonTime: Double?
    private var cloth = ClothSimulation()
    private var bassLevel: Float = 0
    private var trebleLevel: Float = 0
    private var trebleDetector = ClothBassDetector.treble
    private var bassDetector = ClothBassDetector()
    private var lastClothTime: Double?
    private let depthState: MTLDepthStencilState?
    private let spectrumBuffer: OpaquePointer
    private let commandQueue: MTLCommandQueue
    private let textureLoader: MTKTextureLoader
    private let fallbackTexture: MTLTexture
    private var artworkTexture: MTLTexture?
    private var artworkImage: CGImage?
    private var pipelines: [VisualizerShader: MTLRenderPipelineState] = [:]
    private var bands = [Float](repeating: 0, count: Int(SCSpectrumBandCount))
    private let animationStartTime = ProcessInfo.processInfo.systemUptime
#if DEBUG
    private var shaderReloaders: [VisualizerShader: VisualizerShaderReloader] = [:]
#endif

    init?(view: MTKView, spectrumBuffer: OpaquePointer, accent: ArtworkAccent) {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            return nil
        }

        do {
            for shader in VisualizerShader.allCases {
                pipelines[shader] = try Self.makePipeline(
                    device: device, library: library, pixelFormat: view.colorPixelFormat,
                    shader: shader
                )
            }
        } catch {
            return nil
        }

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depth)
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
                device: device, pixelFormat: view.colorPixelFormat, shader: shader
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

    fileprivate static func makePipeline(
        device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat,
        shader: VisualizerShader
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
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
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private typealias PistonFrame = (positions: MTLBuffer, uniforms: [SIMD4<Float>], vertexCount: Int)

    private func preparePistons(in view: MTKView) -> PistonFrame? {
        let now = ProcessInfo.processInfo.systemUptime
        pistons.settings = pistonSettings
        pistons.advance(delta: lastPistonTime.map { now - $0 } ?? PistonSimulation.step, bands: bands)
        lastPistonTime = now
        let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        // Fit the full row in narrow windows as well as landscape windows.
        let distance = max(13, 17 / max(0.1, aspect)) * clothCamera.zoom / 0.7
        let pitchRange = VisualizerShader.pistons.cameraPitchRange
        let pitch = min(pitchRange.upperBound, max(pitchRange.lowerBound, clothCamera.pitch))
        var uniforms = [SIMD4<Float>(aspect, clothCamera.yaw, pitch + 0.25, distance)]
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
        uniforms.append(SIMD4<Float>(pistonSettings.stripeThickness, pistonSettings.stripeFrequency, 0, 0))
        uniforms.append(SIMD4<Float>(pistonSettings.stripeColor, 0))
        uniforms.append(SIMD4<Float>(pistonSettings.metalColor, 0))
        uniforms.append(SIMD4<Float>(pistonSettings.baseColor, 0))
        uniforms.append(SIMD4<Float>(pistonSettings.roughness, pistonSettings.metallic,
                                     pistonSettings.grainStrength, pistonSettings.grainScale))
        uniforms.append(SIMD4<Float>(pistonSettings.reflectionStrength, pistonSettings.edgeSoftness, 0, 0))
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
        let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        cloth.advance(delta: delta)
        // Each command owns its snapshot until the GPU completes the frame.
        let buffer = cloth.positions.withUnsafeBytes { bytes in
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
            let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
            let distance = sqrt(clothSettings.width * clothSettings.width +
                                clothSettings.height * clothSettings.height) * 1.35 * clothCamera.zoom
            // Keep the receiving wall behind the rotated mesh.
            let cy = cos(clothCamera.yaw), sy = sin(clothCamera.yaw)
            let cp = cos(clothCamera.pitch), sp = sin(clothCamera.pitch)
            let minimumDepth = cloth.positions.reduce(Float(0)) { depth, p in
                min(depth, sp * p.y + cp * (-sy * p.x + cy * p.z))
            }
            let wallDepth = min(-size * 0.12, minimumDepth - size * 0.04)
            // Five header float4s and 64 pairs, matching ClothUniforms in Metal.
            var uniforms = [
                SIMD4<Float>(Float(cloth.columns), Float(cloth.rows), clothSettings.width, clothSettings.height),
                SIMD4<Float>(aspect, clothCamera.yaw, clothCamera.pitch, distance),
                SIMD4<Float>(clothSettings.shineIntensity, Float(cloth.ripples.count),
                             clothSettings.showMesh ? 1 : 0, 0),
                SIMD4<Float>(wallDepth, 0.48, 0, 0),
                SIMD4<Float>(clothSettings.chromaticAberration, clothSettings.iridescence,
                             clothSettings.rippleThickness, 0)
            ]
            for ripple in cloth.ripples {
                uniforms.append(SIMD4(ripple.origin.x, ripple.origin.y,
                                      ripple.age / ClothSimulation.rippleTravelDuration, ripple.strength))
                let trailAge = max(0, ripple.age - ClothSimulation.rippleTravelDuration)
                    / ClothSimulation.rippleTrailDuration
                uniforms.append(SIMD4(ripple.radius, ripple.isTreble ? 1 : 0, trailAge, ripple.age))
            }
            uniforms.append(contentsOf: repeatElement(SIMD4<Float>.zero,
                count: (ClothSimulation.maximumRipples - cloth.ripples.count) * 2))
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
        encoder.setFragmentTexture(fallbackTexture, index: 1)
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
            encoder.setFragmentTexture(fallbackTexture, index: 1)
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
        let blur = MPSImageGaussianBlur(device: device, sigma: max(1, Float(min(width, height)) * 0.008))
        blur.edgeMode = .zero
        blur.encode(commandBuffer: commandBuffer, sourceTexture: shadowMask, destinationTexture: shadowBlur)
        return shadowBlur
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
        guard let pipelineState = pipelines[shader],
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
                              pipeline: pipelineState, frame: $0)
        } ?? pistonFrame.flatMap {
            encodePistonShadow(in: view, commandBuffer: commandBuffer,
                               pipeline: pipelineState, frame: $0)
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPassDescriptor
              ) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        bands.withUnsafeBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.setFragmentTexture(fallbackTexture, index: 1)
        encoder.setFragmentTexture(artworkTexture ?? fallbackTexture, index: 0)
        var elapsedTime = Float(ProcessInfo.processInfo.systemUptime - animationStartTime)
        encoder.setFragmentBytes(
            &elapsedTime,
            length: MemoryLayout<Float>.stride,
            index: 3
        )
        var accentColor = SIMD4<Float>(
            Float(accent.red), Float(accent.green), Float(accent.blue),
            artworkTexture == nil ? 0 : 1
        )
        encoder.setFragmentBytes(
            &accentColor,
            length: MemoryLayout<SIMD4<Float>>.stride,
            index: 2
        )
        var viewWidth = Float(view.bounds.width)
        encoder.setFragmentBytes(
            &viewWidth,
            length: MemoryLayout<Float>.size,
            index: 1
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
            }
        } else if shader == .cloth {
            if let frame = clothFrame {
                var uniforms = frame.uniforms
                encoder.setVertexBuffer(frame.positions, offset: 0, index: 0)
                encoder.setFragmentBuffer(frame.normals, offset: 0, index: 5)
                if let shadow = frameShadow {
                    uniforms[2].w = 2
                    uniforms.withUnsafeBytes { bytes in
                        encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
                        encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
                    }
                    encoder.setFragmentTexture(shadow, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                uniforms[2].w = 0
                uniforms.withUnsafeBytes { bytes in
                    encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
                    encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 4)
                }
                encoder.setDepthStencilState(depthState)
                encoder.setFrontFacing(.counterClockwise)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: (cloth.columns - 1) * (cloth.rows - 1) * 6)
            }
        } else {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
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
    private var pendingPipeline: MTLRenderPipelineState?

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, shader: VisualizerShader) {
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

    func takePipeline() -> MTLRenderPipelineState? {
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
            let pipeline = try VisualizerRenderer.makePipeline(
                device: device, library: library, pixelFormat: pixelFormat, shader: shader
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
