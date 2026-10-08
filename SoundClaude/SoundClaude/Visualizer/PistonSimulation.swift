import Foundation
import simd

struct PistonSettings: Equatable {
    var stringsPerPiston = 24
    var ropeLength: Float = 2.59
    var ropeStretchiness: Float = 0.15
    var ropeThickness: Float = 0.024
    var neutralRopeGlow: Float = 1.0
    var bloomStrength: Float = 1.5
    var damping: Float = 0.04
    var gravity: Float = 20
    var travel: Float = 2.7
    var suddenChangeSmoothing: Float = 2 // Smooth large, fast movements only; zero disables it.
    var motionSmoothing: Float = 0.25 // Multiplier of the original rise/fall smoothing; zero disables it.
    var headTwist: Float = 90 // Degrees over a full rise.
    var stripeThickness: Float = 0.0192
    var stripeFrequency: Float = 1
    var stripeColor = SIMD3<Float>(0.144, 0.162, 0.189) // Linear RGB.
    var metalColor = SIMD3<Float>(0.523, 0.788, 1.0) // Linear RGB.
    var baseColor = SIMD3<Float>(0.279823, 0.353969, 0.415926) // Linear RGB.
    var groundColor = SIMD3<Float>(0.233544, 0.285116, 0.314244) // Linear RGB.
    var backgroundColor = SIMD3<Float>(repeating: 0.000619195) // sRGB 0.008 in linear RGB.
    var backgroundGlowColor = SIMD3<Float>(0.0469642, 0.0835351, 0.162647) // Linear RGB.
    var roughness: Float = 0.21
    var metallic: Float = 0.20
    var reflectionStrength: Float = 0.42
    var edgeSoftness: Float = 0.05

    func twistAngle(height: Float) -> Float {
        guard travel > 0 else { return 0 }
        return min(1, max(0, (height - 0.8) / travel)) * headTwist * .pi / 180
    }
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

    static func root(_ string: Int, height: Float, stringsPerPiston: Int = 24, twist: Float = 0) -> SIMD4<Float> {
        let piston = string / stringsPerPiston
        let angle = Float(string % stringsPerPiston) * 2 * .pi / Float(stringsPerPiston) + twist
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
            let root = Self.root(string, height: heights[piston], stringsPerPiston: settings.stringsPerPiston,
                                 twist: settings.twistAngle(height: heights[piston]))
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
        // Allow 2.5% of full travel per physics step without filtering. Smooth
        // only the excess, so small changes and gradual ramps have no added lag.
        let immediateTravel = abs(settings.travel) * 0.025
        let suddenChangeRiseRate: Float = settings.suddenChangeSmoothing > 0 ? 1 - pow(0.78, 1 / settings.suddenChangeSmoothing) : 1
        let suddenChangeFallRate: Float = settings.suddenChangeSmoothing > 0 ? 1 - pow(0.925, 1 / settings.suddenChangeSmoothing) : 1
        let motionRiseRate: Float = settings.motionSmoothing > 0
            ? 1 - pow(0.78, 1 / settings.motionSmoothing) : 1
        let motionFallRate: Float = settings.motionSmoothing > 0
            ? 1 - pow(0.925, 1 / settings.motionSmoothing) : 1
        while accumulator >= Self.step {
            accumulator -= Self.step
            let previousHeights = heights
            for piston in heights.indices {
                let change = targets[piston] - heights[piston]
                let motionRate = change > 0 ? motionRiseRate : motionFallRate
                let excess = max(0, abs(change) - immediateTravel)
                if excess == 0 || settings.suddenChangeSmoothing <= 0 {
                    heights[piston] = motionRate == 1
                        ? targets[piston] : heights[piston] + change * motionRate
                    continue
                }
                let rate = change > 0 ? suddenChangeRiseRate : suddenChangeFallRate
                let movement = abs(change) - excess * (1 - rate)
                // Apply the separate motion filter to every movement,
                // including the travel allowed through the sudden-change filter.
                heights[piston] += (change > 0 ? movement : -movement) * motionRate
            }
            // Move only the pinned roots. Free nodes follow through the rope
            // constraints, retaining inertia as the heads turn and reverse.
            for string in 0..<(Self.count * settings.stringsPerPiston) {
                let height = heights[string / settings.stringsPerPiston]
                positions[string * (Self.segments + 1)] = Self.root(string,
                    height: height, stringsPerPiston: settings.stringsPerPiston,
                    twist: settings.twistAngle(height: height))
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
                                settings.damping, settings.gravity, settings.ropeStretchiness)
                        }
                    }
                }
            }
        }
    }
}
