import Foundation
import simd

struct ClothSettings: Equatable {
    var columns = 65
    var rows = 49
    var width: Float = 6
    var height: Float = 4.5
    var damping: Float = 0.015
    var stiffness: Float = 0.85
    var gravity: Float = 0.65
    var impulseStrength: Float = 1
    var impulseRadius: Float = 1.8
    var iterations = 6
}

struct ClothCamera {
    var yaw: Float = 0.35
    var pitch: Float = 0
    var zoom: Float = 1
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
        for i in positions.indices where !isPinned(i) {
            let p = positions[i]
            let falloff = exp(-(p.x * p.x + p.y * p.y) / (settings.impulseRadius * settings.impulseRadius))
            previous[i].z -= nextDirection * amount * falloff
        }
        nextDirection *= -1
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
