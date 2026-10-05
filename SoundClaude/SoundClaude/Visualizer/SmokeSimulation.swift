import Foundation
import Metal
import MetalPerformanceShaders

struct SmokeSettings {
    var resolution = 640 // Longest grid side in cells; changing it restarts the fluid.
    var sensitivity: Float = 0.38
    var spread: Float = 0.37 // Fraction of the view puffs spawn within.
    var puffSize: Float = 3
    var force: Float = 3
    var turbulence: Float = 2.33
    var swirl: Float = 51.8 // Vorticity confinement.
    var drag: Float = 0.65
    var viscosity: Float = 0 // Velocity smoothing rate; 0 preserves fine motion.
    var pressureIterations = 20
    var diffusion: Float = 3
    var decay: Float = 1
    var brightness: Float = 4
    var hotCores: Float = 0.75 // Blend bright smoke toward white; 0 disables it.
    var glow: Float = 3
    var glowRadius: Float = 24 // Grid cells.
    var bloomStrength: Float = 0.8
    var bloomRadius: Float = 16 // Gaussian blur sigma in grid cells.
    var bloomWideStrength: Float = 0.35 // Outer halo at three times the bloom radius.
    var bloomThreshold: Float = 1 // Brightness before tone mapping.
    var hueShift: Float = 0 // Degrees; applies to newly emitted smoke.
    var hueSpeed: Float = 3 // Degrees per second; 0 stops the hue cycle.
    var hueSpread: Float = 0.47 // Radians between adjacent frequency groups.
    var saturation: Float = 1.2

    static var liquid: SmokeSettings {
        var settings = SmokeSettings()
        settings.force = 1.5
        settings.turbulence = 0.5
        settings.swirl = 12
        settings.drag = 0.2
        settings.viscosity = 24
        settings.diffusion = 0
        settings.decay = 0.05
        settings.pressureIterations = 40
        settings.hotCores = 0
        settings.glow = 0.5
        settings.bloomStrength = 0.3
        settings.brightness = 2
        return settings
    }

    /// Matches `float4 display` in smokeVisualizerFragment.
    var display: SIMD4<Float> { SIMD4(glow, brightness, glowRadius, bloomStrength) }
}

/// Eight frequency groups match the piston palette. A steady tone stops emitting.
struct SmokeOnsets {
    private var envelope = [Float](repeating: 0, count: 8)
    private var cooldown = [Float](repeating: 0, count: 8)

    mutating func advance(bands: [Float], delta: Float, sensitivity: Float) -> [Float] {
        guard delta.isFinite, delta > 0 else { return Array(repeating: 0, count: 8) }
        let dt = min(delta, 0.05)
        return (0..<8).map { band -> Float in
            let lo = band * bands.count / 8, hi = (band + 1) * bands.count / 8
            let level = bands[lo..<hi].reduce(Float(0)) {
                $0 + ($1.isFinite ? min(1, max(0, $1)) : 0)
            } / Float(max(1, hi - lo))
            let rise = max(0, level - envelope[band])
            envelope[band] += (level - envelope[band]) * (1 - exp(-dt * 18))
            cooldown[band] = max(0, cooldown[band] - dt)
            guard rise * sensitivity > 0.025, cooldown[band] == 0 else { return 0 }
            cooldown[band] = 0.12
            return min(1.5, (rise * sensitivity - 0.025) * 3)
        }
    }
}

final class SmokeSimulation {
    private let device: MTLDevice
    private var kernels: [String: MTLComputePipelineState] = [:]
    private var velocity: [MTLTexture] = []
    private var dye: [MTLTexture] = []
    private var pressure: [MTLTexture] = []
    private var divergence: MTLTexture?
    private var bloom: [MTLTexture] = []
    var bloomTexture: MTLTexture? { bloom.last }
    private var bloomBlur: MPSImageGaussianBlur?
    private var wideBloomBlur: MPSImageGaussianBlur?
    private var onsets = SmokeOnsets()
    private var lastTime: Double?
    private var huePhase: Float = 0
    private var needsClear = true

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        for name in ["Clear", "Velocity", "Vorticity", "Divergence", "Pressure", "Project", "Dye", "Bloom", "BloomCombine"] {
            guard let function = library.makeFunction(name: "smoke" + name) else {
                throw NSError(domain: "SmokeSimulation", code: 1)
            }
            kernels[name] = try device.makeComputePipelineState(function: function)
        }
    }

    func reset() {
        lastTime = nil
        huePhase = 0
        onsets = SmokeOnsets()
        needsClear = true
    }

    func encode(commandBuffer: MTLCommandBuffer, width: Int, height: Int,
                bands: [Float], settings: SmokeSettings,
                time: Double = ProcessInfo.processInfo.systemUptime) -> MTLTexture? {
        let scale = min(1, Float(settings.resolution) / Float(max(1, max(width, height))))
        let w = max(16, Int(Float(width) * scale)), h = max(16, Int(Float(height) * scale))
        if dye.first?.width != w || dye.first?.height != h {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            let textures = (0..<11).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            guard textures.count == 11 else { return nil }
            velocity = Array(textures[0..<2]); dye = Array(textures[2..<4])
            pressure = Array(textures[4..<6]); divergence = textures[6]
            bloom = Array(textures[7..<11])
            reset()
        }
        guard let divergence, let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.label = "2D smoke fluid"
        let elapsed: Double = lastTime.map { time - $0 } ?? (1.0 / 60.0)
        let dt = Float(min(1.0 / 30.0, max(1.0 / 240.0, elapsed)))
        // Advance with real frame time, but skip long gaps while the view is inactive.
        if lastTime != nil {
            huePhase = (huePhase + settings.hueSpeed * Float(min(0.1, max(0, elapsed))))
                .truncatingRemainder(dividingBy: 360)
        }
        lastTime = time
        // Grid-space units keep puffs round at every viewport aspect ratio.
        var uniforms = [SIMD4<Float>(Float(w), Float(h), dt, settings.decay),
                        SIMD4(settings.drag, settings.swirl, settings.diffusion, settings.viscosity),
                        SIMD4(settings.puffSize, settings.force, settings.turbulence, 0),
                        SIMD4((settings.hueShift + huePhase) * .pi / 180, settings.hueSpread, settings.saturation, 0)]
        let margin = (1 - min(1, max(0, settings.spread))) / 2
        let strengths = onsets.advance(bands: bands, delta: dt, sensitivity: settings.sensitivity)
        for strength in strengths {
            let angle = Float.random(in: 0...(2 * .pi))
            uniforms.append(SIMD4(Float.random(in: margin...(1 - margin)) * Float(w),
                                  Float.random(in: margin...(1 - margin)) * Float(h),
                                  cos(angle), sin(angle)))
            uniforms.append(SIMD4<Float>(strength, Float.random(in: 0...(2 * .pi)), 0, 0))
        }
        uniforms.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        func dispatch(_ name: String, _ textures: [MTLTexture]) {
            encoder.setComputePipelineState(kernels[name]!)
            for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
            encoder.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        }
        if needsClear {
            for texture in velocity + dye + pressure + [divergence] { dispatch("Clear", [texture]) }
            needsClear = false
        }
        dispatch("Velocity", [velocity[0], velocity[1]])
        dispatch("Vorticity", [velocity[1], velocity[0]])
        dispatch("Divergence", [velocity[0], divergence])
        dispatch("Clear", [pressure[0]])
        for _ in 0..<min(60, max(4, settings.pressureIterations)) {
            dispatch("Pressure", [pressure[0], divergence, pressure[1]])
            pressure.swapAt(0, 1)
        }
        dispatch("Project", [velocity[0], pressure[0], velocity[1]])
        velocity.swapAt(0, 1)
        dispatch("Dye", [dye[0], velocity[0], dye[1]])
        dye.swapAt(0, 1)
        if settings.bloomStrength > 0 {
            var extraction = SIMD4<Float>(settings.brightness, settings.bloomThreshold, 0, 0)
            encoder.setBytes(&extraction, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            dispatch("Bloom", [dye[0], bloom[0]])
        }
        encoder.endEncoding()
        if settings.bloomStrength > 0 {
            let sigma = max(1, settings.bloomRadius)
            if bloomBlur?.sigma != sigma {
                bloomBlur = MPSImageGaussianBlur(device: device, sigma: sigma)
                bloomBlur?.edgeMode = .zero
            }
            bloomBlur?.encode(commandBuffer: commandBuffer, sourceTexture: bloom[0], destinationTexture: bloom[1])
            if settings.bloomWideStrength > 0 {
                let wideSigma = sigma * 3
                if wideBloomBlur?.sigma != wideSigma {
                    wideBloomBlur = MPSImageGaussianBlur(device: device, sigma: wideSigma)
                    wideBloomBlur?.edgeMode = .zero
                }
                wideBloomBlur?.encode(commandBuffer: commandBuffer, sourceTexture: bloom[0], destinationTexture: bloom[2])
            }
            guard let combine = commandBuffer.makeComputeCommandEncoder() else { return nil }
            combine.label = "Layered smoke bloom"
            combine.setComputePipelineState(kernels["BloomCombine"]!)
            combine.setTexture(bloom[1], index: 0)
            combine.setTexture(bloom[2], index: 1)
            combine.setTexture(bloom[3], index: 2)
            var wideStrength = settings.bloomWideStrength
            combine.setBytes(&wideStrength, length: MemoryLayout<Float>.size, index: 0)
            combine.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            combine.endEncoding()
        }
        return dye[0]
    }
}
