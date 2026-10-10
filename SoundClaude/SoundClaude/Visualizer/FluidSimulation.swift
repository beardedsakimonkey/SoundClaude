import MetalKit
import simd

struct FluidSettings {
    var curl: Float = 30
    var force: Float = 1
    var radius: Float = 0.25
    var dyeDissipation: Float = 1
    var velocityDissipation: Float = 0.2
    var brightness: Float = 1
    var bloom: Float = 0.8
    var shading = true
    var sunrays = true
}

struct FluidDisplayUniforms {
    var texelAndStyle: SIMD4<Float>
    var effects: SIMD4<Float>

    init(size: CGSize, settings: FluidSettings) {
        texelAndStyle = SIMD4(1 / Float(size.width), 1 / Float(size.height),
                             settings.brightness, settings.shading ? 1 : 0)
        effects = SIMD4(settings.sunrays ? 1 : 0, settings.bloom, 0, 0)
    }
}

struct FluidTouch {
    var sequence = 0
    var point = SIMD2<Float>(0.5, 0.5)
    var delta = SIMD2<Float>.zero
}

/// Detect attacks in eight logarithmic frequency groups from the normalized spectrum.
struct FluidBandDetector {
    static let colors: [SIMD3<Float>] = [
        SIMD3(1, 0.04, 0.02), SIMD3(1, 0.3, 0.02),
        SIMD3(1, 0.8, 0.02), SIMD3(0.2, 1, 0.08),
        SIMD3(0.02, 1, 0.7), SIMD3(0.02, 0.5, 1),
        SIMD3(0.25, 0.08, 1), SIMD3(0.8, 0.04, 1)
    ]
    struct Hit {
        let band: Int
        let strength: Float
        var color: SIMD3<Float> { FluidBandDetector.colors[band] * 0.15 }
    }
    private var previous = [Float](repeating: 0, count: 8)
    private var baseline = [Float](repeating: 0, count: 8)
    private var cooldown = [Double](repeating: 0, count: 8)
    private var primed = false

    mutating func update(bands: [Float], delta: Double) -> [Hit] {
        guard bands.count >= 8 else { return [] }
        let elapsed = delta.isFinite ? max(0, delta) : 0
        let blend = Float(1 - exp(-elapsed / 0.25))
        var hits: [Hit] = []
        for band in 0..<8 {
            let lower = band * bands.count / 8
            let upper = (band + 1) * bands.count / 8
            let level = bands[lower..<upper].reduce(Float(0)) {
                $0 + ($1.isFinite ? min(1, max(0, $1)) : 0)
            } / Float(upper - lower)
            let energy = level * level
            cooldown[band] = max(0, cooldown[band] - elapsed)
            if primed, cooldown[band] == 0, energy > 0.015,
               energy - previous[band] > 0.008,
               energy > baseline[band] * 1.5 + 0.01 {
                hits.append(Hit(band: band, strength: min(1, (energy - baseline[band]) / 0.3)))
                cooldown[band] = 0.12
            }
            baseline[band] = primed ? baseline[band] + (energy - baseline[band]) * blend : energy
            previous[band] = energy
        }
        // Do not treat an already playing track as a new attack on entry or resume.
        primed = true
        return hits
    }
}

/// Metal port of Pavel Dobryakov's WebGL fluid solver. See Fluid-LICENSE.txt.
/// Velocity uses grid cells/second; dye uses a separate, finer grid.
final class FluidSimulation {
    private struct Uniforms {
        var step = SIMD4<Float>.zero // dt, dissipation, curl, aspect
        var splat = SIMD4<Float>.zero // position, radius squared, operation
        var value = SIMD4<Float>.zero
    }
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let postPipeline: MTLComputePipelineState
    private var bloomDown: [MTLTexture] = []
    private var bloomUp: [MTLTexture] = []
    private var rays: [MTLTexture] = []
    private var randomState: UInt64
    private var pointerColor = SIMD3<Float>.zero
    private var colorTimer: Float = 0
    private var bandDetector = FluidBandDetector()

    // Match getResolution in the reference, with a cap for unusually wide windows.
    private func resolution(_ base: Int, aspect: Float, limit: Int) -> (Int, Int) {
        let w = Float(base) * max(1, aspect)
        let h = Float(base) / min(1, aspect)
        let scale = min(1, Float(limit) / max(w, h))
        return (max(2, Int((w * scale).rounded())), max(2, Int((h * scale).rounded())))
    }

    private func random() -> Float {
        randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
        return Float(randomState >> 40) / 16777216
    }

    private func color() -> SIMD3<Float> {
        let h = random() * 6
        let f = h - floor(h)
        let rgb: SIMD3<Float>
        switch Int(h) {
        case 0: rgb = SIMD3(1, f, 0)
        case 1: rgb = SIMD3(1 - f, 1, 0)
        case 2: rgb = SIMD3(0, 1, f)
        case 3: rgb = SIMD3(0, 1 - f, 1)
        case 4: rgb = SIMD3(f, 0, 1)
        default: rgb = SIMD3(1, 0, 1 - f)
        }
        return rgb * 0.15
    }
    private var velocity: [MTLTexture] = []
    private var dye: [MTLTexture] = []
    private var pressure: [MTLTexture] = []
    private var curl: MTLTexture?
    private var divergence: MTLTexture?
    private var lastTime: Double?
    private var lastTouch = 0
    private var initialized = false

    init(device: MTLDevice, library: MTLLibrary, seed: UInt64 = .random(in: .min ... .max)) throws {
        randomState = seed
        self.device = device
        guard let function = library.makeFunction(name: "fluidStep"),
              let post = library.makeFunction(name: "fluidPost") else {
            throw NSError(domain: "FluidSimulation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing fluidStep shader"])
        }
        pipeline = try device.makeComputePipelineState(function: function)
        postPipeline = try device.makeComputePipelineState(function: post)
    }

    func suspend() {
        lastTime = nil
        bandDetector = FluidBandDetector()
    }

    private func texture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    func encode(commandBuffer: MTLCommandBuffer, size: CGSize, settings: FluidSettings,
                bands: [Float], touch: FluidTouch,
                now: Double = CACurrentMediaTime()) -> MTLTexture? {
        guard size.width > 0, size.height > 0 else { return nil }
        // Bound both grids, including very wide or tall windows.
        let aspect = Float(size.width / size.height)
        let (width, height) = resolution(128, aspect: aspect, limit: 512)
        let (dyeWidth, dyeHeight) = resolution(1024, aspect: aspect, limit: 2048)
        if velocity.first?.width != width || velocity.first?.height != height
            || dye.first?.width != dyeWidth || dye.first?.height != dyeHeight {
            guard let v0 = texture(width: width, height: height),
                  let v1 = texture(width: width, height: height),
                  let d0 = texture(width: dyeWidth, height: dyeHeight),
                  let d1 = texture(width: dyeWidth, height: dyeHeight),
                  let p0 = texture(width: width, height: height),
                  let p1 = texture(width: width, height: height),
                  let c = texture(width: width, height: height),
                  let div = texture(width: width, height: height) else { return nil }
            velocity = [v0, v1]; dye = [d0, d1]; pressure = [p0, p1]
            curl = c; divergence = div
            initialized = false
            lastTime = nil
        }
        guard let curl, let divergence else { return nil }
        let elapsed = max(0, now - (lastTime ?? (now - 1.0 / 60)))
        if elapsed > 0.5 { bandDetector = FluidBandDetector() }
        let hits = bandDetector.update(bands: bands, delta: elapsed)
        let dt = Float(min(1.0 / 60, elapsed))
        lastTime = now
        var uniforms = Uniforms()
        uniforms.step = SIMD4(dt, 0, settings.curl, aspect)

        func pass(_ operation: Float, _ source: MTLTexture, _ other: MTLTexture,
                  _ target: MTLTexture) {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            uniforms.splat.w = operation
            encoder.label = "Fluid pass \(Int(operation))"
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(other, index: 1)
            encoder.setTexture(target, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
        }
        if !initialized {
            for target in velocity + dye + pressure + [curl, divergence] {
                // Clear does not read its inputs, but keep bindings disjoint.
                pass(0, target === velocity[0] ? velocity[1] : velocity[0],
                     target === velocity[0] ? velocity[1] : velocity[0], target)
            }
        }
        func splat(_ point: SIMD2<Float>, _ motion: SIMD2<Float>, _ color: SIMD3<Float>, _ amount: Float) {
            uniforms.splat = SIMD4(point.x, point.y, settings.radius / 100 * max(1, aspect), 1)
            uniforms.value = SIMD4(motion.x, motion.y, 0, 0)
            pass(1, velocity[0], velocity[0], velocity[1]); velocity.swapAt(0, 1)
            uniforms.value = SIMD4(color * amount, 0)
            pass(1, dye[0], dye[0], dye[1]); dye.swapAt(0, 1)
        }
        if !initialized {
            // The reference starts with 5–24 rainbow splats at up to 500 cells/second.
            let count = 5 + Int(random() * 20)
            for _ in 0..<count {
                let tint = color()
                let point = SIMD2(random(), random())
                let motion = SIMD2(random() - 0.5, random() - 0.5) * 1000
                splat(point, motion, tint, 10)
            }
            pointerColor = color()
            initialized = true
        }
        colorTimer += dt * 10
        if colorTimer >= 1 {
            colorTimer.formTruncatingRemainder(dividingBy: 1)
            pointerColor = color()
        }
        func corrected(_ delta: SIMD2<Float>) -> SIMD2<Float> {
            delta * SIMD2(min(1, aspect), 1 / max(1, aspect))
        }
        for hit in hits {
            let point = SIMD2(0.08 + random() * 0.84, 0.08 + random() * 0.84)
            let angle = random() * 2 * Float.pi
            let motion = corrected(SIMD2(cos(angle), sin(angle)))
                * (250 + 750 * hit.strength) * settings.force
            splat(point, motion, hit.color, 3 + 7 * hit.strength)
        }
        if touch.sequence != lastTouch {
            lastTouch = touch.sequence
            splat(touch.point, corrected(touch.delta) * 6000, pointerColor, 1)
        }
        pass(2, velocity[0], velocity[0], curl)
        pass(3, velocity[0], curl, velocity[1]); velocity.swapAt(0, 1)
        pass(4, velocity[0], velocity[0], divergence)
        pass(8, pressure[0], pressure[0], pressure[1]); pressure.swapAt(0, 1)
        for _ in 0..<20 {
            pass(5, pressure[0], divergence, pressure[1]); pressure.swapAt(0, 1)
        }
        pass(6, pressure[0], velocity[0], velocity[1]); velocity.swapAt(0, 1)
        uniforms.step.y = settings.velocityDissipation
        pass(7, velocity[0], velocity[0], velocity[1]); velocity.swapAt(0, 1)
        uniforms.step.y = settings.dyeDissipation
        pass(7, dye[0], velocity[0], dye[1]); dye.swapAt(0, 1)
        return dye[0]
    }

    /// Reference bloom pyramid and radial light scattering, encoded before display.
    func encodeEffects(commandBuffer: MTLCommandBuffer, dye: MTLTexture,
                       size: CGSize, settings: FluidSettings) -> (bloom: MTLTexture, rays: MTLTexture)? {
        guard size.width > 0, size.height > 0 else { return nil }
        let aspect = Float(size.width / size.height)
        let (bw, bh) = resolution(256, aspect: aspect, limit: 512)
        let (rw, rh) = resolution(196, aspect: aspect, limit: 392)
        if bloomDown.first?.width != bw || bloomDown.first?.height != bh
            || rays.first?.width != rw || rays.first?.height != rh {
            var down: [MTLTexture] = []
            var up: [MTLTexture] = []
            for level in 0...8 {
                let w = bw >> level, h = bh >> level
                if w < 2 || h < 2 { break }
                guard let a = texture(width: w, height: h), let b = texture(width: w, height: h) else { return nil }
                down.append(a); up.append(b)
            }
            guard let r0 = texture(width: rw, height: rh), let r1 = texture(width: rw, height: rh) else { return nil }
            bloomDown = down; bloomUp = up; rays = [r0, r1]
        }
        func pass(_ op: Float, _ source: MTLTexture, _ other: MTLTexture,
                  _ target: MTLTexture, scale: Float = 1) {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            var params = SIMD4<Float>(op, scale, 0, 0)
            encoder.label = "Fluid display effect \(Int(op))"
            encoder.setComputePipelineState(postPipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(other, index: 1)
            encoder.setTexture(target, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
        }
        pass(0, dye, dye, bloomDown[0])
        for level in 1..<bloomDown.count {
            pass(1, bloomDown[level - 1], dye, bloomDown[level])
        }
        var last = bloomDown.last!
        for level in stride(from: bloomDown.count - 2, through: 1, by: -1) {
            pass(2, last, bloomDown[level], bloomUp[level])
            last = bloomUp[level]
        }
        pass(1, last, dye, bloomUp[0], scale: settings.bloom)
        // The spare dye buffer is safe scratch: the next simulation pass overwrites it.
        let mask = self.dye[1]
        pass(3, dye, dye, mask)
        pass(4, mask, mask, rays[0])
        pass(5, rays[0], dye, rays[1])
        pass(6, rays[1], dye, rays[0])
        return (bloomUp[0], rays[0])
    }

}
