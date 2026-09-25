import Foundation
import simd

struct ClothSettings: Equatable {
    var columns = 41
    var rows = 31
    var width: Float = 10
    var height: Float = 4.5
    var damping: Float = 0.015
    var compliance: Float = 0.0001
    var bendCompliance: Float = 0.1
    var gravity: Float = 3
    var impulseStrength: Float = 2
    var impulseRadius: Float = 1.7
    var trebleImpulseStrength: Float = 0.14
    var trebleImpulseRadius: Float = 1.4
    var iterations = 1
    var shineIntensity: Float = 0.25
    var showMesh = false
}

struct ClothCamera: Equatable {
    var yaw: Float = 0
    var pitch: Float = 0
    var zoom: Float = 0.9
}

struct ClothRipple {
    var origin: SIMD2<Float>
    var age: Float = 0
    var strength: Float
    var radius: Float
    var isTreble: Bool
}

/// Fixed-step XPBD cloth with distance and signed dihedral bending constraints.
struct ClothSimulation {
    private(set) var settings: ClothSettings
    var columns: Int { settings.columns }
    var rows: Int { settings.rows }
    static let step: Double = 1 / 120
    private(set) var positions: [SIMD4<Float>] = []
    private var previous: [SIMD4<Float>] = []
    private var edges: [SCClothEdge] = []
    private var bends: [SCClothBend] = []
    private var accumulator: Double = 0
    private(set) var nextDirection: Float = 1
    private(set) var bassPulse: Float = 0
    private(set) var bassPulseLevel: Float = 0
    private(set) var treblePulse: Float = 0
    private(set) var treblePulseLevel: Float = 0
    private(set) var trebleOrigin = SIMD2<Float>.zero
    private(set) var nextTrebleDirection: Float = 1
    private var trebleHits = 0
    // Travel time covers the cloth; the remaining trail fades only after arrival.
    static let rippleTravelDuration: Float = 3.75
    static let rippleTrailDuration: Float = 1.5
    static let rippleLifetime = rippleTravelDuration + rippleTrailDuration
    // Covers both detectors at their maximum hit rates for the full lifetime.
    static let maximumRipples = 64
    private(set) var ripples: [ClothRipple] = []

    private mutating func addRipple(origin: SIMD2<Float>, strength: Float,
                                    radius: Float, isTreble: Bool) {
        if ripples.count == Self.maximumRipples { ripples.removeFirst() }
        ripples.append(ClothRipple(origin: origin, strength: min(1, max(0, strength)),
                                   radius: radius, isTreble: isTreble))
    }

    func isPinned(_ index: Int) -> Bool {
        let x = index % columns, y = index / columns
        return (x == 0 || x == columns - 1) && (y == 0 || y == rows - 1)
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
                if x + 1 < columns {
                    addEdge(a, a + 1)
                    if y > 0 && y + 1 < rows { addBend(a, a + 1, a - columns + 1, a + columns) }
                }
                if y + 1 < rows {
                    addEdge(a, a + columns)
                    if x > 0 && x + 1 < columns { addBend(a, a + columns, a + 1, a + columns - 1) }
                }
                if x + 1 < columns && y + 1 < rows {
                    addEdge(a, a + columns + 1)
                    addEdge(a + 1, a + columns)
                    // Match the rendered triangles: (a, below, right),
                    // (right, below, belowRight). Every interior edge is a hinge.
                    addBend(a + columns, a + 1, a, a + columns + 1)
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
            aWeight: aPinned ? 0 : 1,
            bWeight: bPinned ? 0 : 1, lambda: 0
        ))
    }

    private mutating func addBend(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        // The initial mesh is flat, with consistent triangle winding.
        bends.append(SCClothBend(a: UInt32(a), b: UInt32(b), c: UInt32(c), d: UInt32(d),
                                 restAngle: 0, lambda: 0))
    }

    mutating func impulse(strength: Float) {
        addRipple(origin: .zero, strength: strength, radius: settings.impulseRadius, isTreble: false)
        bassPulse = 1
        bassPulseLevel = min(1, max(0, strength))
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

    /// Smaller scattered hits around the outer cloth, as in see_the_music.
    mutating func trebleImpulse(strength: Float) {
        trebleHits += 1
        let angle = Float(trebleHits) * 2.39996
        let outerRadius = Float.random(in: 0.72..<0.88)
        trebleOrigin = SIMD2(cos(angle) * settings.width, sin(angle) * settings.height) * (0.5 * outerRadius)
        addRipple(origin: trebleOrigin, strength: strength,
                  radius: settings.trebleImpulseRadius, isTreble: true)
        treblePulse = 1
        treblePulseLevel = min(1, max(0, strength))
        let amount = settings.trebleImpulseStrength * (0.5 + 1.15 * treblePulseLevel)
        let scatterAngle = Float.random(in: 0..<(2 * .pi))
        let tilt = Float.random(in: 0.192..<0.384)
        let direction = SIMD4<Float>(cos(scatterAngle) * tilt, sin(scatterAngle) * tilt,
                                     nextTrebleDirection * sqrt(1 - tilt * tilt), 0)
        let radiusSquared = max(0.0001, settings.trebleImpulseRadius * settings.trebleImpulseRadius)
        for i in positions.indices where !isPinned(i) {
            let offset = SIMD2(positions[i].x, positions[i].y) - trebleOrigin
            previous[i] -= direction * amount * exp(-simd_length_squared(offset) / radiusSquared)
        }
        nextTrebleDirection *= -1
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
        for i in ripples.indices { ripples[i].age += Float(max(0, delta)) }
        ripples.removeAll { $0.age >= Self.rippleLifetime }
        // Keep the impulse envelopes independent of the longer visual ripples.
        bassPulse = max(0, bassPulse - Float(max(0, delta)) * 2.7)
        treblePulse = max(0, treblePulse - Float(max(0, delta)) * 5.2)
        // Limit catch-up after a suspended window; never use a large physics step.
        accumulator += min(1 / 15, max(0, delta))
        // Borrow each array once, outside the solver loops. This avoids Swift's
        // per-element exclusivity and copy-on-write checks in Debug builds.
        let columns = columns, rows = rows, settings = settings
        positions.withUnsafeMutableBufferPointer { positions in
            previous.withUnsafeMutableBufferPointer { previous in
                edges.withUnsafeMutableBufferPointer { edges in
                    bends.withUnsafeMutableBufferPointer { bends in
                        while accumulator + 1e-10 >= Self.step {
                            accumulator -= Self.step
                            SCClothStep(positions.baseAddress!, previous.baseAddress!,
                                        UInt32(columns), UInt32(rows),
                                        edges.baseAddress!, UInt32(edges.count),
                                        bends.baseAddress, UInt32(bends.count),
                                        settings.damping, settings.compliance, settings.bendCompliance, settings.gravity,
                                        UInt32(settings.iterations))
                        }
                    }
                }
            }
        }
    }
}

/// Port of see_the_music's bass detector with the tuned audio settings.
struct ClothBassDetector {
    var threshold: Float = 1.4
    // Captured playback can have bass peaks below 0.02. Keep the noise floor
    // below those peaks; the relative threshold still rejects sustained bass.
    var floor: Float = 0.002
    var cooldown: Double = 0.14
    var fullHitEnergy: Float = 0.12

    static var treble: Self {
        Self(threshold: 3, floor: 0, cooldown: 0.25, fullHitEnergy: 0.0005)
    }

    private var history: [(time: Double, energy: Float)] = []
    private var previousEnergy: Float = 0
    private var time: Double = 0
    private var lastBeat = -Double.infinity

    mutating func update(level: Float, delta: Double) -> Float? {
        let level = level.isFinite ? min(1, max(0, level)) : 0
        time += delta.isFinite ? max(0, delta) : 0
        let energy = level * level
        history.removeAll { time - $0.time > 0.75 }
        if history.count == 512 { history.removeFirst() }
        history.append((time, energy))
        let mean = history.reduce(Float(0)) { $0 + $1.energy } / Float(history.count)
        let rising = energy > previousEnergy
        previousEnergy = energy
        guard energy > floor, rising, energy > mean * threshold,
              time - lastBeat > cooldown else { return nil }
        lastBeat = time
        // Match getHitLevel's smoothstep from the floor to full-hit energy.
        let amount = min(1, max(0, (energy - floor) / (fullHitEnergy - floor)))
        return amount * amount * (3 - 2 * amount)
    }
}
