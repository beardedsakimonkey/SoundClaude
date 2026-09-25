import Foundation
import simd

struct ClothSettings: Equatable {
    var columns = 97
    var rows = 73
    var width: Float = 6
    var height: Float = 4.5
    var damping: Float = 0.015
    var stiffness: Float = 0.85
    var gravity: Float = 3
    var impulseStrength: Float = 1
    var impulseRadius: Float = 2.0
    var iterations = 6
    var shineIntensity: Float = 0.25
    var gridlineOpacity: Float = 0
}

struct ClothCamera: Equatable {
    var yaw: Float = 0
    var pitch: Float = 0
    var zoom: Float = 1
}

/// Shared audio response for the cloth lighting and its backdrop.
struct ClothLightEnvelope {
    private(set) var level = 0.0
    var brightness: Double { 0.35 + 0.65 * level }

    mutating func update(rms: Float, delta: Double) {
        let target = rms.isFinite ? min(1, max(0, Double(rms) * 4)) : 0
        let response = target > level ? 0.08 : 0.35
        level += (target - level) * (1 - exp(-max(0, delta) / response))
    }
}

/// A fixed-step Verlet cloth with structural and diagonal distance constraints.
struct ClothSimulation {
    private(set) var settings: ClothSettings
    var columns: Int { settings.columns }
    var rows: Int { settings.rows }
    static let step: Double = 1 / 120
    private(set) var positions: [SIMD4<Float>] = []
    private var previous: [SIMD4<Float>] = []
    private var edges: [SCClothEdge] = []
    private var accumulator: Double = 0
    private(set) var nextDirection: Float = 1

    func isPinned(_ index: Int) -> Bool {
        let x = index % columns, y = index / columns
        return (x == 0 || x == columns - 1) && y == 0
    }

    init(settings: ClothSettings = ClothSettings()) {
        self.settings = settings
        for y in 0..<rows {
            for x in 0..<columns {
                positions.append(SIMD4(Float(x) / Float(columns - 1) * settings.width - settings.width / 2,
                                       settings.height / 2 - Float(y) / Float(rows - 1) * settings.height, 0, 0))
            }
        }
        previous = positions
        for y in 0..<rows {
            for x in 0..<columns {
                let a = y * columns + x
                if x + 1 < columns { addEdge(a, a + 1) }
                if y + 1 < rows { addEdge(a, a + columns) }
                if x + 1 < columns && y + 1 < rows {
                    addEdge(a, a + columns + 1)
                    addEdge(a + 1, a + columns)
                }
            }
        }
    }

    mutating func configure(_ settings: ClothSettings) {
        guard settings != self.settings else { return }
        if settings.columns != columns || settings.rows != rows ||
            settings.width != self.settings.width || settings.height != self.settings.height {
            self = ClothSimulation(settings: settings)
        } else {
            self.settings = settings
        }
    }

    private mutating func addEdge(_ a: Int, _ b: Int) {
        let aPinned = isPinned(a), bPinned = isPinned(b)
        edges.append(SCClothEdge(
            a: UInt32(a), b: UInt32(b), rest: simd_length(positions[b] - positions[a]),
            aWeight: aPinned ? 0 : (bPinned ? 1 : 0.5),
            bWeight: bPinned ? 0 : (aPinned ? 1 : 0.5)
        ))
    }

    mutating func impulse(strength: Float) {
        let amount = (min(1, max(0, strength)) * 0.13 + 0.035) * settings.impulseStrength
        // Match see_the_music's bass scatter, with a fresh tilt for each hit.
        let scatterAngle = Float.random(in: 0..<(2 * .pi))
        let tilt: Float = 0.24 * (0.45 + Float.random(in: 0..<1) * 0.55)
        let direction = SIMD4<Float>(cos(scatterAngle) * tilt, sin(scatterAngle) * tilt,
                                     nextDirection * sqrt(max(0, 1 - tilt * tilt)), 0)
        for i in positions.indices where !isPinned(i) {
            let p = positions[i]
            let falloff = exp(-(p.x * p.x + p.y * p.y) / (settings.impulseRadius * settings.impulseRadius))
            previous[i] -= direction * amount * falloff
        }
        nextDirection *= -1
    }

    /// Sweep a soft brush over the projected mesh. Coordinates match Metal's
    /// normalized device coordinates, with positive Y toward the top of the view.
    mutating func brush(from start: SIMD2<Float>, to end: SIMD2<Float>,
                        camera: ClothCamera, aspect: Float) {
        guard aspect.isFinite, aspect > 0,
              start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { return }
        // Measure screen distances in units of the shorter viewport dimension.
        let metric = SIMD2<Float>(max(1, aspect), max(1, 1 / aspect))
        let movement = (end - start) * metric
        let length = simd_length(movement)
        guard length > 0.00001 else { return }
        let direction = movement / length
        let amount = min(length, 0.2) * 0.45
        let cy = cos(camera.yaw), sy = sin(camera.yaw)
        let cp = cos(camera.pitch), sp = sin(camera.pitch)
        let distance = sqrt(settings.width * settings.width + settings.height * settings.height)
            * 1.35 * camera.zoom
        let scale = min(2.6, 2.6 * aspect)
        // The resting cloth lies in the simulation's XY plane. Push along
        // its fixed normal; camera rotation only affects where the brush lands.
        let impulse = SIMD4<Float>(0, 0, -amount, 0)
        let radius: Float = 0.09
        for i in positions.indices where !isPinned(i) {
            let p = positions[i]
            let turned = SIMD3<Float>(cy * p.x + sy * p.z, p.y, -sy * p.x + cy * p.z)
            let world = SIMD3<Float>(turned.x, cp * turned.y - sp * turned.z,
                                      sp * turned.y + cp * turned.z)
            let depth = distance - world.z
            guard depth > 0.1 else { continue }
            let projected = SIMD2(world.x * scale / aspect, world.y * scale) / depth
            let offset = (projected - start) * metric
            let t = min(1, max(0, simd_dot(offset, direction) / length))
            let separation = simd_length(offset - movement * t) / radius
            guard separation < 1 else { continue }
            let falloff = (1 - separation * separation)
            previous[i] -= impulse * falloff * falloff
        }
    }

    mutating func advance(delta: Double) {
        // Limit catch-up after a suspended window; never use a large physics step.
        accumulator += min(1 / 15, max(0, delta))
        // Borrow each array once, outside the solver loops. This avoids Swift's
        // per-element exclusivity and copy-on-write checks in Debug builds.
        let columns = columns, rows = rows, settings = settings
        positions.withUnsafeMutableBufferPointer { positions in
            previous.withUnsafeMutableBufferPointer { previous in
                edges.withUnsafeBufferPointer { edges in
                    while accumulator + 1e-10 >= Self.step {
                        accumulator -= Self.step
                        SCClothStep(positions.baseAddress!, previous.baseAddress!,
                                    UInt32(columns), UInt32(rows),
                                    edges.baseAddress!, UInt32(edges.count),
                                    settings.damping, settings.stiffness, settings.gravity,
                                    UInt32(settings.iterations))
                    }
                }
            }
        }
    }
}

/// Detect rising bass energy, with hysteresis and a refractory period.
struct ClothBassDetector {
    private var baseline: Float = 0
    private var previous: Float = 0
    private var cooldown: Double = 0
    private var armed = true

    mutating func update(level: Float, delta: Double) -> Float? {
        let level = level.isFinite ? min(1, max(0, level)) : 0
        let dt = min(0.1, max(0, delta))
        cooldown = max(0, cooldown - dt)
        let rise = level - previous
        previous = level
        let excess = level - baseline
        baseline += (level - baseline) * Float(1 - exp(-dt / 0.35))
        if excess < 0.025 || level < 0.08 { armed = true }
        guard armed, cooldown == 0, level > 0.12, excess > 0.065, rise > 0.012 else {
            return nil
        }
        armed = false
        cooldown = 0.18
        return min(1, excess * 3)
    }
}
