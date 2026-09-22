import Foundation
import MetalKit

enum VisualizerShader: String, CaseIterable {
    case bars
    case ribbon

    var next: Self {
        let shaders = Self.allCases
        let index = shaders.firstIndex(of: self)!
        return shaders[(index + 1) % shaders.count]
    }

    var title: String { self == .bars ? "Bars" : "Ribbon" }
    var sourceFile: String { self == .bars ? "AudioVisualizer.metal" : "RibbonVisualizer.metal" }
    var vertexFunction: String { self == .bars ? "visualizerVertex" : "ribbonVisualizerVertex" }
    var fragmentFunction: String { self == .bars ? "visualizerFragment" : "ribbonVisualizerFragment" }
}

final class VisualizerRenderer: NSObject, MTKViewDelegate {
    var accent: ArtworkAccent
    var shader: VisualizerShader = .bars

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
        return try device.makeRenderPipelineState(descriptor: descriptor)
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
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPassDescriptor
              ) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
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
        bands.withUnsafeMutableBufferPointer { pointer in
            _ = SCSpectrumBufferRead(spectrumBuffer, pointer.baseAddress, nil)
            encoder.setFragmentBytes(
                pointer.baseAddress!,
                length: pointer.count * MemoryLayout<Float>.stride,
                index: 0
            )
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
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
