import Foundation
import Metal

struct SmokeSettings {
    var resolution = 640 // Longest grid side in cells; changing it restarts the fluid.
    var sensitivity: Float = 1
    var spread: Float = 0.7 // Fraction of the view puffs spawn within.
    var puffSize: Float = 1
    var force: Float = 1
    var turbulence: Float = 1
    var buoyancy: Float = 0 // Upward lift per unit of smoke density.
    var swirl: Float = 18 // Vorticity confinement.
    var drag: Float = 0.65
    var diffusion: Float = 3
    var decay: Float = 0.55
    var brightness: Float = 1.7
    var glow: Float = 1.2
    var glowRadius: Float = 9 // Grid cells.
    var hueShift: Float = 0 // Degrees; applies to newly emitted smoke.
    var hueSpread: Float = 0.47 // Radians between adjacent frequency groups.
    var saturation: Float = 1

    /// Matches `float4 display` in smokeVisualizerFragment.
    var display: SIMD4<Float> { SIMD4(glow, brightness, glowRadius, 0) }
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
    private var onsets = SmokeOnsets()
    private var lastTime: Double?
    private var needsClear = true

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        for name in ["Clear", "Velocity", "Vorticity", "Divergence", "Pressure", "Project", "Dye"] {
            guard let function = library.makeFunction(name: "smoke" + name) else {
                throw NSError(domain: "SmokeSimulation", code: 1)
            }
            kernels[name] = try device.makeComputePipelineState(function: function)
        }
    }

    func reset() {
        lastTime = nil
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
            let textures = (0..<7).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            guard textures.count == 7 else { return nil }
            velocity = Array(textures[0..<2]); dye = Array(textures[2..<4])
            pressure = Array(textures[4..<6]); divergence = textures[6]
            reset()
        }
        guard let divergence, let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.label = "2D smoke fluid"
        let elapsed: Double = lastTime.map { time - $0 } ?? (1.0 / 60.0)
        let dt = Float(min(1.0 / 30.0, max(1.0 / 240.0, elapsed)))
        lastTime = time
        // Grid-space units keep puffs round at every viewport aspect ratio.
        var uniforms = [SIMD4<Float>(Float(w), Float(h), dt, settings.decay),
                        SIMD4(settings.drag, settings.swirl, settings.diffusion, settings.buoyancy),
                        SIMD4(settings.puffSize, settings.force, settings.turbulence, 0),
                        SIMD4(settings.hueShift * .pi / 180, settings.hueSpread, settings.saturation, 0)]
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
        dispatch("Velocity", [velocity[0], velocity[1], dye[0]])
        dispatch("Vorticity", [velocity[1], velocity[0]])
        dispatch("Divergence", [velocity[0], divergence])
        dispatch("Clear", [pressure[0]])
        for _ in 0..<20 {
            dispatch("Pressure", [pressure[0], divergence, pressure[1]])
            pressure.swapAt(0, 1)
        }
        dispatch("Project", [velocity[0], pressure[0], velocity[1]])
        velocity.swapAt(0, 1)
        dispatch("Dye", [dye[0], velocity[0], dye[1]])
        dye.swapAt(0, 1)
        encoder.endEncoding()
        return dye[0]
    }
}
