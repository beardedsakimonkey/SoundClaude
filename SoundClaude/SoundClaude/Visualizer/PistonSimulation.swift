import Foundation
import simd

struct PistonSettings: Equatable {
    var stringsPerPiston = 24
    var ropeLength: Float = 2.59
    var ropeThickness: Float = 0.024
    var neutralRopeGlow: Float = 1.0
    var damping: Float = 0.032
    var gravity: Float = 20
    var travel: Float = 3.2
    var stripeThickness: Float = 0.0192
    var stripeFrequency: Float = 1
    var stripeColor = SIMD3<Float>(0.144, 0.162, 0.189) // Linear RGB.
    var metalColor = SIMD3<Float>(0.56, 0.62, 0.70) // Linear RGB.
    var baseColor = SIMD3<Float>(0.15, 0.19, 0.25) // Linear RGB.
    var roughness: Float = 0.26
    var metallic: Float = 0.94
    var grainStrength: Float = 1
    var grainScale: Float = 1
    var reflectionStrength: Float = 0.5
    var edgeSoftness: Float = 0.018
}

/// Independent ropes with pinned roots and Verlet distance constraints.
struct PistonSimulation {
    var settings = PistonSettings() {
        didSet {
            if settings.stringsPerPiston != oldValue.stringsPerPiston { resetRopes() }
        }
    }
    static let count = 8
    static let stringsPerPiston = 24
    static let segments = 20
    static let step = 1.0 / 120
    static let segmentLength: Float = 0.115
    private(set) var heights = [Float](repeating: 0.8, count: count)
    private(set) var positions: [SIMD4<Float>] = []
    private var previous: [SIMD4<Float>] = []
    private var accumulator = 0.0

    static func center(_ piston: Int) -> SIMD3<Float> {
        SIMD3((Float(piston) - 3.5) * 1.85, 0, 0)
    }

    static func root(_ string: Int, height: Float, stringsPerPiston: Int = 24) -> SIMD4<Float> {
        let piston = string / stringsPerPiston
        let angle = Float(string % stringsPerPiston) * 2 * .pi / Float(stringsPerPiston)
        // Inset from the circular cap edge so each rope hangs from its underside.
        let radius: Float = 0.57
        let offset = SIMD2(radius * cos(angle), radius * sin(angle))
        let center = center(piston)
        return SIMD4(center.x + offset.x, height - 0.055, offset.y, 0)
    }

    init() { resetRopes() }

    private mutating func resetRopes() {
        positions.removeAll(keepingCapacity: true)
        positions.reserveCapacity(Self.count * settings.stringsPerPiston * (Self.segments + 1))
        for string in 0..<(Self.count * settings.stringsPerPiston) {
            let piston = string / settings.stringsPerPiston
            let root = Self.root(string, height: heights[piston], stringsPerPiston: settings.stringsPerPiston)
            let center = Self.center(piston)
            let outward = simd_normalize(SIMD3(root.x - center.x, 0, root.z))
            for node in 0...Self.segments {
                let distance = Float(node) * settings.ropeLength / Float(Self.segments)
                positions.append(root + SIMD4(outward.x * distance * 0.12,
                                              -distance, outward.z * distance * 0.12, 0))
            }
        }
        previous = positions
    }

    mutating func advance(delta: Double, bands: [Float]) {
        guard delta.isFinite, delta > 0 else { return }
        accumulator += min(delta, 1.0 / 15)
        let targets: [Float] = (0..<Self.count).map { piston in
            let lower = piston * bands.count / Self.count
            let upper = (piston + 1) * bands.count / Self.count
            let energy = bands[lower..<upper].reduce(Float(0)) { sum, value in
                sum + (value.isFinite ? min(1, max(0, value)) : 0)
            } / Float(max(1, upper - lower))
            return 0.8 + energy * settings.travel
        }
        while accumulator >= Self.step {
            accumulator -= Self.step
            let previousHeights = heights
            for piston in heights.indices {
                let rate: Float = targets[piston] > heights[piston] ? 0.22 : 0.075
                heights[piston] += (targets[piston] - heights[piston]) * rate
            }
            // Borrow each array once, avoiding Swift's per-node mutation overhead
            // in Debug builds. The C kernel is optimized in every configuration.
            positions.withUnsafeMutableBufferPointer { points in
                previous.withUnsafeMutableBufferPointer { old in
                    heights.withUnsafeBufferPointer { levels in
                        previousHeights.withUnsafeBufferPointer { previousLevels in
                            SCPistonStep(points.baseAddress!, old.baseAddress!, levels.baseAddress!,
                                previousLevels.baseAddress!, settings.ropeThickness * 0.5,
                                UInt32(Self.count * settings.stringsPerPiston), UInt32(settings.stringsPerPiston),
                                UInt32(Self.segments), settings.ropeLength / Float(Self.segments),
                                settings.damping, settings.gravity)
                        }
                    }
                }
            }
        }
    }
}
