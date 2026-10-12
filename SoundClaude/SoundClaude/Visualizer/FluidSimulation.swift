import MetalKit
import simd

struct FluidSettings {
    var curl: Float = 30
    var force: Float = 1
    var steadyFlow: Float = 0.6
    var topEmitterSpray: Float = 1
    var middleEmitterSpray: Float = 1
    var bottomEmitterSpray: Float = 1
    var emitterSlideSpeed: Float = 1
    var radius: Float = 0.1
    var topEmitterSize: Float = 1.2
    var middleEmitterSize: Float = 0.7
    var bottomEmitterSize: Float = 1.4
    var hueVariation: Float = 12
    var showEmitters = false
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
    var emitters: SIMD4<Float>

    init(size: CGSize, settings: FluidSettings, emitterPositions: SIMD3<Float> = .zero,
         middleEmitterY: Float = 0.5) {
        texelAndStyle = SIMD4(1 / Float(size.width), 1 / Float(size.height),
                             settings.brightness, settings.shading ? 1 : 0)
        effects = SIMD4(settings.sunrays ? 1 : 0, settings.bloom, middleEmitterY, 0)
        emitters = SIMD4(emitterPositions, settings.showEmitters ? 1 : 0)
    }
}

struct FluidTouch {
    var sequence = 0
    var point = SIMD2<Float>(0.5, 0.5)
    var delta = SIMD2<Float>.zero
}

/// Drive continuous flow and detect attacks in eight logarithmic frequency groups.
struct FluidBandDetector {
    static let colors: [SIMD3<Float>] = [
        SIMD3(1, 0.04, 0.02), SIMD3(1, 0.3, 0.02),
        SIMD3(1, 0.8, 0.02), SIMD3(0.2, 1, 0.08),
        SIMD3(0.02, 1, 0.7), SIMD3(0.02, 0.5, 1),
        SIMD3(0.25, 0.08, 1), SIMD3(0.8, 0.04, 1)
    ]
    struct Emission {
        let band: Int
        let strength: Float
        // Attacks are impulses; continuous flow scales with elapsed time.
        let scale: Float
        let isAttack: Bool
        var color: SIMD3<Float> { FluidBandDetector.colors[band] * 0.15 }
    }
    private var previous = [Float](repeating: 0, count: 8)
    private var baseline = [Float](repeating: 0, count: 8)
    private var cooldown = [Double](repeating: 0, count: 8)
    private var primed = false

    mutating func update(bands: [Float], delta: Double) -> [Emission] {
        guard bands.count >= 8 else { return [] }
        let elapsed = delta.isFinite ? max(0, delta) : 0
        let blend = Float(1 - exp(-elapsed / 0.25))
        var emissions: [Emission] = []
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
                emissions.append(Emission(band: band, strength: min(1, (energy - baseline[band]) / 0.3),
                                          scale: 1, isAttack: true))
                cooldown[band] = 0.12
            }
            // Keep steady sounds visible after their attack. Gate low-level noise and
            // cap elapsed time so an interruption cannot create a large splat.
            if energy > 0.015, elapsed > 0 {
                let strength = min(1, (energy - 0.015) / 0.3)
                emissions.append(Emission(band: band, strength: strength,
                                          scale: Float(min(elapsed, 1.0 / 60)) * strength,
                                          isAttack: false))
            }
            baseline[band] = primed ? baseline[band] + (energy - baseline[band]) * blend : energy
            previous[band] = energy
        }
        // Do not treat an already playing track as a new attack on entry or resume.
        primed = true
        return emissions
    }
}

/// Detect closing filters from the high/mid balance, relative to recent audio.
struct FluidFilterDrag {
    private var roll: Float?
    private var history: [Float] = []
    private var sampleTime: Double = 0
    private var reference: Float = 0
    private var slowClosure: Float = 0
    private(set) var extraDamping: Float = 0

    mutating func update(bands: [Float], delta: Double) {
        guard bands.count >= 8, delta.isFinite, delta > 0, delta <= 0.5 else {
            self = FluidFilterDrag()
            return
        }
        var mid: Float = 0, high: Float = 0, midLevel: Float = 0
        var midCount: Float = 0, highCount: Float = 0
        for (index, sample) in bands.enumerated() {
            let level = sample.isFinite ? min(1, max(0, sample)) : 0
            // SpectrumAnalyzer publishes logarithmic bands from 30 Hz to 18 kHz,
            // with levels mapped from -72 to -12 dB. Recover approximate power.
            let frequency = 30 * pow(600.0, (Double(index) + 0.5) / Double(bands.count))
            let power = max(0, pow(Float(10), level * 6 - 7.2) - pow(Float(10), -7.2))
            if frequency >= 150 && frequency < 2500 {
                mid += power; midLevel += level; midCount += 1
            } else if frequency >= 5000 && frequency < 12000 {
                high += power; highCount += 1
            }
        }
        guard midCount > 0, highCount > 0, midLevel / midCount > 0.12 else {
            // Silence must not look like a filter closing, including when audio returns.
            self = FluidFilterDrag()
            return
        }
        let ratio = min(10, (high / highCount) / max(mid / midCount, 1e-10))
        let smoothed = (roll ?? ratio) + (ratio - (roll ?? ratio)) * Float(1 - exp(-delta / 0.25))
        roll = smoothed
        sampleTime += delta
        if history.isEmpty || sampleTime >= 0.1 {
            sampleTime.formTruncatingRemainder(dividingBy: 0.1)
            history.append(smoothed)
            if history.count > 300 { history.removeFirst() }
            reference = history.sorted()[Int(Double(history.count - 1) * 0.9)]
        }
        let closure: Float = reference > 1e-8 ? max(0, min(1, 1 - smoothed / reference)) : 0
        slowClosure += (closure - slowClosure) * Float(1 - exp(-delta))
        func smooth(_ low: Float, _ high: Float, _ value: Float) -> Float {
            let t = min(1, max(0, (value - low) / (high - low)))
            return t * t * (3 - 2 * t)
        }
        // Only a darkening mix adds drag. A steady dark mix returns to normal.
        extraDamping = 2.8 * smooth(0.8, 0.97, closure) * smooth(0.03, 0.12, closure - slowClosure)
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
    private var filterDrag = FluidFilterDrag()
    private var splatPhase: Double = 0

    var emitterPositions: SIMD3<Float> {
        SIMD3((0..<3).map { row in
            Float(0.5 - 0.42 * cos(splatPhase + Double(row) * 2 * .pi / 3))
        })
    }

    var middleEmitterY: Float {
        // Two vertical cycles per horizontal cycle trace a shallow figure-eight.
        0.5 + 0.06 * Float(sin(2 * (splatPhase + 2 * .pi / 3)))
    }

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
        hueColor(random() * 6) * 0.15
    }

    // Hue is measured in six sectors, wrapping at red.
    private func hueColor(_ hue: Float) -> SIMD3<Float> {
        let h = hue - floor(hue / 6) * 6
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
        return rgb
    }

    private func variedColor(_ color: SIMD3<Float>, degrees: Float) -> SIMD3<Float> {
        guard degrees > 0 else { return color }
        let low = min(color.x, min(color.y, color.z))
        let high = max(color.x, max(color.y, color.z))
        let chroma = high - low
        guard chroma > 0 else { return color }
        let hue: Float
        if high == color.x {
            hue = (color.y - color.z) / chroma
        } else if high == color.y {
            hue = 2 + (color.z - color.x) / chroma
        } else {
            hue = 4 + (color.x - color.y) / chroma
        }
        // Shift hue while preserving the band's saturation and brightness.
        return hueColor(hue + (random() * 2 - 1) * degrees / 60) * chroma
            + SIMD3<Float>(repeating: low)
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
        filterDrag = FluidFilterDrag()
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
        let emissions = bandDetector.update(bands: bands, delta: elapsed)
        filterDrag.update(bands: bands, delta: elapsed)
        let dt = Float(min(1.0 / 60, elapsed))
        // At 1× speed without filter drag, complete a sweep every six seconds.
        // Slow emitter travel with the same high fade that damps the fluid.
        let slideSpeed = settings.emitterSlideSpeed / (1 + filterDrag.extraDamping)
        // Freeze during long interruptions so resuming does not jump the emitters.
        if elapsed <= 0.5 {
            splatPhase = (splatPhase + elapsed * Double(slideSpeed) * 2 * .pi / 6)
                .truncatingRemainder(dividingBy: 2 * .pi)
        }
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
        func splat(_ point: SIMD2<Float>, _ motion: SIMD2<Float>, _ color: SIMD3<Float>,
                   _ amount: Float, radiusScale: Float = 1) {
            // The shader uses radius squared, so square the scale for a linear size change.
            let radiusSquared = settings.radius / 100 * max(1, aspect) * radiusScale * radiusScale
            uniforms.splat = SIMD4(point.x, point.y, radiusSquared, 1)
            uniforms.value = SIMD4(motion.x, motion.y, 0, 0)
            pass(1, velocity[0], velocity[0], velocity[1]); velocity.swapAt(0, 1)
            uniforms.value = SIMD4(color * amount, 0)
            pass(1, dye[0], dye[0], dye[1]); dye.swapAt(0, 1)
        }
        if !initialized {
            // Start clear; only audio and pointer input add dye.
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
        let positions = emitterPositions
        for emission in emissions {
            // Rows move continuously, each one third of a cycle apart.
            let row = emission.band < 2 ? 0 : (emission.band < 6 ? 1 : 2)
            let spray = row == 0 ? settings.bottomEmitterSpray
                : (row == 1 ? settings.middleEmitterSpray : settings.topEmitterSpray)
            let scale = emission.scale * (emission.isAttack ? 1 : settings.steadyFlow * spray)
            guard scale > 0 else { continue }
            let x = positions[row]
            let point = SIMD2<Float>(x, row == 0 ? 0.91 : (row == 1 ? middleEmitterY : 0.09))
            let direction: SIMD2<Float>
            if row == 1 {
                // Match the middle row’s position phase: point right at the left
                // edge and left at the right edge, rotating once per sweep.
                let angle = Float(splatPhase + 2 * .pi / 3)
                direction = SIMD2(cos(angle), sin(angle))
            } else {
                // Velocity is in grid cells, so account for the grid's aspect ratio
                // before normalizing the vector toward the screen center.
                let toCenter = (SIMD2<Float>(repeating: 0.5) - point)
                    * SIMD2(Float(width), Float(height))
                direction = simd_normalize(toCenter)
            }
            let motion = direction * (250 + 750 * emission.strength) * settings.force * scale
            // Scale each row relative to the shared splat radius.
            let rowRadiusScale = row == 0 ? settings.bottomEmitterSize
                : (row == 1 ? settings.middleEmitterSize : settings.topEmitterSize)
            splat(point, motion, variedColor(emission.color, degrees: settings.hueVariation), (3 + 7 * emission.strength) * scale,
                  radiusScale: (0.5 + emission.strength) * rowRadiusScale)
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
        uniforms.step.y = settings.velocityDissipation + filterDrag.extraDamping
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
