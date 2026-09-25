import Foundation
import MetalKit
import MetalPerformanceShaders
import simd

enum VisualizerShader: String, CaseIterable {
    case bars
    case inkPool
    case cloth

    var next: Self {
        let shaders = Self.allCases
        let index = shaders.firstIndex(of: self)!
        return shaders[(index + 1) % shaders.count]
    }

    var title: String {
        switch self {
        case .bars: "Bars"
        case .inkPool: "Ink Pool"
        case .cloth: "Cloth"
        }
    }

    var sourceFile: String {
        switch self {
        case .bars: "AudioVisualizer.metal"
        case .inkPool: "InkPoolVisualizer.metal"
        case .cloth: "ClothVisualizer.metal"
        }
    }

    private var functionPrefix: String {
        switch self {
        case .bars: "visualizer"
        case .inkPool: "inkPoolVisualizer"
        case .cloth: "clothVisualizer"
        }
    }

    var vertexFunction: String { functionPrefix + "Vertex" }
    var fragmentFunction: String { functionPrefix + "Fragment" }
}

// Keep the field order and Float types in sync with InkPoolSettings in the Metal shader.
struct InkPoolSettings {
    var speed: Float = 0.18
    var flowScale: Float = 3.0
    var warpStrength: Float = 0.32
    var bassResponse: Float = 1.0
    var rippleFrequency: Float = 16.0
    var rippleStrength: Float = 0.3
    var surfaceDepth: Float = 0.45
    var artworkScale: Float = 0.19
    var refraction: Float = 1.0
    var sheen: Float = 0.17
    var glints: Float = 2.8
}

final class VisualizerRenderer: NSObject, MTKViewDelegate {
    var accent: ArtworkAccent
    var shader: VisualizerShader = .bars
    var inkPoolSettings = InkPoolSettings()
    var clothSettings = ClothSettings()
    var clothCamera = ClothCamera()

    private var shadowMask: MTLTexture?
    private var shadowBlur: MTLTexture?
    private var shadowDepth: MTLTexture?
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
        encoder.label = "Cloth wall shadow mask"
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
        let frameShadow = clothFrame.flatMap {
            encodeClothShadow(in: view, commandBuffer: commandBuffer,
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
        if shader == .inkPool {
            var settings = inkPoolSettings
            encoder.setFragmentBytes(
                &settings, length: MemoryLayout<InkPoolSettings>.stride, index: 4
            )
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
        if shader == .cloth {
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
            lastClothTime = nil
            bassDetector = ClothBassDetector()
            trebleDetector = .treble
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
