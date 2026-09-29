import Foundation
import simd

@main
struct PistonSimulationTests {
    static func checkStretch(_ simulation: PistonSimulation) {
        let segmentLength = simulation.settings.ropeLength / Float(PistonSimulation.segments)
        for string in 0..<(PistonSimulation.count * simulation.settings.stringsPerPiston) {
            let start = string * (PistonSimulation.segments + 1)
            for node in 1...PistonSimulation.segments {
                let length = simd_distance(simulation.positions[start + node],
                                           simulation.positions[start + node - 1])
                precondition(length.isFinite && length <= segmentLength * (1.101 + 0.75 * simulation.settings.ropeStretchiness),
                             "Transient rope stretch: string \(string), node \(node), ratio \(length / segmentLength)")
            }
        }
    }

    static func checkCollisions(_ simulation: PistonSimulation) {
        let radius = simulation.settings.ropeThickness * 0.5 - 0.001
        for string in 0..<(PistonSimulation.count * simulation.settings.stringsPerPiston) {
            let start = string * (PistonSimulation.segments + 1)
            let root = simulation.positions[start]
            precondition(simulation.positions[start + 1].y <= root.y - radius,
                         "First rope segment crosses the cap underside")
            // The root is pinned to the cap underside. Check all other segments,
            // including their interiors, against the visible piston geometry.
            for node in 2...PistonSimulation.segments {
                for fraction: Float in [0, 0.25, 0.5, 0.75, 1] {
                    let p = simulation.positions[start + node - 1] * (1 - fraction)
                        + simulation.positions[start + node] * fraction
                    for piston in 0..<PistonSimulation.count {
                        let x = p.x - PistonSimulation.center(piston).x
                        let height = simulation.heights[piston]
                        let insideCap = hypot(x, p.z) < 0.65 + radius
                            && abs(p.y - height) < 0.055 + radius
                        let radialDistance = hypot(x, p.z)
                        let insideBase = radialDistance < 0.38 + radius
                            && p.y > -1.65 - radius && p.y < -1.41 + radius
                        let insideShaft = radialDistance < 0.22 + radius
                            && p.y > -1.53 - radius && p.y < height + radius
                        precondition(!insideCap && !insideBase && !insideShaft,
                                     "String intersects piston \(piston) at \(p)")
                    }
                }
            }
        }
    }

    static func checkUndersideAttachment() {
        for radius: Float in [0.002, 0.012, 0.04] {
            for height: Float in [0.8, 4] {
                let root = PistonSimulation.root(1, height: height)
                // A rope kicked upward must not emerge through the cap, even
                // when its first free node has already crossed the top surface.
                let above = root + SIMD4<Float>(0, 0.2, 0, 0)
                var points = [root, above]
                var previous = points
                points.withUnsafeMutableBufferPointer { p in
                    previous.withUnsafeMutableBufferPointer { old in
                        SCPistonStep(p.baseAddress!, old.baseAddress!, [height], [height + 0.2],
                                     radius, 1, 1, 1, 0.115, 0, 0, 0)
                    }
                }
                precondition(points[0] == root)
                precondition(points[1].y <= root.y - radius + 0.00001,
                             "Rope escaped through its cap")
            }
        }
    }

    static func checkSweptCollisions() {
        let x = PistonSimulation.center(0).x
        func step(root: SIMD4<Float>, start: SIMD4<Float>, end: SIMD4<Float>,
                  height: Float, previousHeight: Float) -> SIMD4<Float> {
            var root = root
            root.y = height - 0.055
            var points = [root, start]
            var previous = [root, start * 2 - end]
            points.withUnsafeMutableBufferPointer { p in
                previous.withUnsafeMutableBufferPointer { old in
                    SCPistonStep(p.baseAddress!, old.baseAddress!, [height], [previousHeight],
                                 0.012, 1, 1, 1, simd_distance(root, end), 0, 0, 0)
                }
            }
            return points[1]
        }
        // A cap sweeps completely through a stationary node in one step.
        let point = SIMD4<Float>(x + 0.5, 1.3, 0, 0)
        let cap = step(root: SIMD4(x + 3, 1.8, 0, 0), start: point, end: point,
                       height: 1.8, previousHeight: 0.8)
        precondition(cap.y >= 1.8 + 0.055 + 0.011)
        // Nodes cross the entire shaft/base between integration samples.
        for (y, radius): (Float, Float) in [(0, 0.22), (-1.53, 0.38)] {
            let result = step(root: SIMD4(x - 1, 0.8, 0, 0),
                              start: SIMD4(x - 1, y, 0, 0), end: SIMD4(x + 1, y, 0, 0),
                              height: 0.8, previousHeight: 0.8)
            precondition(result.x <= x - radius - 0.011, "Swept cylinder at \(y): \(result)")
        }
    }

    static func checkElasticity() {
        var extensions: [Float] = []
        for stretchiness: Float in [0, PistonSettings().ropeStretchiness, 1] {
            var simulation = PistonSimulation()
            simulation.settings.stringsPerPiston = 4
            simulation.settings.ropeLength = 1
            simulation.settings.travel = 5
            simulation.settings.ropeStretchiness = stretchiness
            let bands = [Float](repeating: 1, count: 64)
            for _ in 0..<600 {
                simulation.advance(delta: PistonSimulation.step, bands: bands)
                checkStretch(simulation)
            }
            let length = simd_distance(simulation.positions[0], simulation.positions[PistonSimulation.segments])
            extensions.append(length)
            checkCollisions(simulation)
            // Remove the load live: elastic extension must recover.
            simulation.settings.gravity = 0
            for _ in 0..<600 { simulation.advance(delta: PistonSimulation.step, bands: bands) }
            // With no gravity the rope can curve, so measure its full length.
            let unloaded = (1...PistonSimulation.segments).reduce(Float(0)) {
                $0 + simd_distance(simulation.positions[$1 - 1], simulation.positions[$1])
            }
            precondition(abs(unloaded - 1) < 0.025, "Rope did not recover: \(unloaded)")
            // Exercise elastic ropes during repeated piston movement and live changes.
            simulation.settings.gravity = 20
            for frame in 0..<360 {
                simulation.advance(delta: PistonSimulation.step,
                    bands: [Float](repeating: frame % 60 < 30 ? 1 : 0, count: 64))
                checkStretch(simulation)
                if frame % 60 == 0 { checkCollisions(simulation) }
            }
            simulation.settings.ropeStretchiness = 0
            for _ in 0..<120 { simulation.advance(delta: PistonSimulation.step, bands: bands) }
            checkStretch(simulation)
        }
        precondition(extensions[1] > extensions[0] + 0.015, "Default stretch must be visible")
        precondition(extensions[2] > extensions[1] + 0.1, "Slider must increase elastic extension")
        precondition(extensions[2] < 1.4, "Elastic extension must remain bounded")
    }

    static func checkHeadTwist() {
        var settings = PistonSettings()
        precondition(abs(settings.twistAngle(height: 0.8 + settings.travel) - .pi / 2) < 0.00001)
        precondition(settings.twistAngle(height: 0.8) == 0)
        settings.travel = 0
        precondition(settings.twistAngle(height: 0.8) == 0)
        for twist: Float in [-360, 0, 90, 360] {
            var simulation = PistonSimulation()
            simulation.settings.stringsPerPiston = 4
            simulation.settings.headTwist = twist
            for frame in 0..<240 {
                let rising = frame < 120
                simulation.advance(delta: PistonSimulation.step,
                    bands: [Float](repeating: rising ? 1 : 0, count: 64))
                for string in 0..<32 {
                    let height = simulation.heights[string / 4]
                    let angle = min(1, max(0, (height - 0.8) / simulation.settings.travel)) * twist * .pi / 180
                    let expected = PistonSimulation.root(string, height: height,
                        stringsPerPiston: 4, twist: angle)
                    precondition(simd_distance(simulation.positions[string * 21], expected) < 0.00001)
                }
                checkStretch(simulation)
                if frame % 30 == 0 { checkCollisions(simulation) }
            }
            // Changing the rope count while raised must keep the rotated roots.
            for _ in 0..<30 {
                simulation.advance(delta: PistonSimulation.step, bands: [Float](repeating: 1, count: 64))
            }
            simulation.settings.stringsPerPiston = 6
            for string in 0..<48 {
                let height = simulation.heights[string / 6]
                let expected = PistonSimulation.root(string, height: height, stringsPerPiston: 6,
                    twist: simulation.settings.twistAngle(height: height))
                precondition(simd_distance(simulation.positions[string * 21], expected) < 0.00001)
            }
            simulation.settings.headTwist = 0
            simulation.advance(delta: PistonSimulation.step, bands: [])
            precondition(simd_distance(simulation.positions[0],
                PistonSimulation.root(0, height: simulation.heights[0], stringsPerPiston: 6)) < 0.00001)
        }
    }

    static func main() {
        checkHeadTwist()
        checkElasticity()
        checkUndersideAttachment()
        checkSweptCollisions()
        var simulation = PistonSimulation()
        simulation.settings.ropeStretchiness = 0
        simulation.settings.headTwist = 0
        var bands = [Float](repeating: 0, count: 64)
        for index in 16..<24 { bands[index] = 1 }
        for _ in 0..<120 { simulation.advance(delta: 1.0 / 120, bands: bands) }
        precondition(simulation.heights[2] > 3.99)
        precondition(abs(simulation.heights[0] - 0.8) < 0.001)
        var split = PistonSimulation()
        var combined = PistonSimulation()
        for _ in 0..<60 { combined.advance(delta: 1.0 / 60, bands: bands) }
        for _ in 0..<120 { split.advance(delta: 1.0 / 120, bands: bands) }
        precondition(zip(split.positions, combined.positions).allSatisfy { simd_distance($0, $1) < 0.0001 })
        for frame in 0..<1200 {
            let input = [Float](repeating: frame % 60 < 30 ? 1 : 0, count: 64)
            simulation.advance(delta: 1.0 / 120, bands: input)
            // Check every step: a rope can stretch for just one frame and then
            // recover, so checks made only after settling miss the regression.
            checkStretch(simulation)
            if frame % 120 == 0 { checkCollisions(simulation) }
        }
        // A delayed frame and invalid input must not corrupt the solver.
        simulation.advance(delta: 10, bands: [.nan, .infinity])
        simulation.advance(delta: .nan, bands: [])
        for _ in 0..<600 { simulation.advance(delta: 1.0 / 120, bands: []) }
        precondition(simulation.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.y >= -1.651 })
        for string in 0..<(PistonSimulation.count * PistonSimulation.stringsPerPiston) {
            let start = string * (PistonSimulation.segments + 1)
            let root = PistonSimulation.root(string, height: simulation.heights[string / PistonSimulation.stringsPerPiston])
            precondition(simd_distance(simulation.positions[start], root) < 0.00001)
            for node in 1...PistonSimulation.segments {
                let length = simd_distance(simulation.positions[start + node], simulation.positions[start + node - 1])
                precondition(abs(length - PistonSimulation.segmentLength) < 0.025)
            }
        }
        precondition(simulation.heights.allSatisfy { abs($0 - 0.8) < 0.001 })
        // Live length and travel changes must reach their new settings without a reset.
        simulation.settings.ropeLength = 1
        simulation.settings.travel = 5
        simulation.settings.gravity = 20
        simulation.settings.damping = 0.08
        for _ in 0..<600 {
            simulation.advance(delta: PistonSimulation.step, bands: [Float](repeating: 1, count: 64))
        }
        precondition(simulation.heights.allSatisfy { abs($0 - 5.8) < 0.001 })
        let tip = simulation.positions[PistonSimulation.segments]
        let root = simulation.positions[0]
        precondition(abs(simd_distance(root, tip) - 1) < 0.1)
        // Exercise the opposite slider limits while the pistons drop.
        simulation.settings.ropeLength = 5
        simulation.settings.travel = 0
        simulation.settings.gravity = 0
        simulation.settings.damping = 0.001
        for _ in 0..<600 {
            simulation.advance(delta: PistonSimulation.step, bands: [Float](repeating: 1, count: 64))
        }
        precondition(simulation.heights.allSatisfy { abs($0 - 0.8) < 0.001 })
        precondition(simulation.positions.allSatisfy {
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.y >= -1.651
        })
        // Changing count resizes all ropes and keeps roots on their owning caps.
        for count in [4, 37, 64, 24] {
            let heights = simulation.heights
            simulation.settings.stringsPerPiston = count
            precondition(simulation.positions.count == PistonSimulation.count * count * 21)
            precondition(simulation.heights == heights)
            for _ in 0..<120 { simulation.advance(delta: PistonSimulation.step, bands: bands) }
            for string in 0..<(PistonSimulation.count * count) {
                let root = PistonSimulation.root(string,
                    height: simulation.heights[string / count], stringsPerPiston: count)
                precondition(simd_distance(simulation.positions[string * 21], root) < 0.00001)
                let center = PistonSimulation.center(string / count)
                precondition(abs(root.y - (simulation.heights[string / count] - 0.055)) < 0.00001)
                precondition(abs(hypot(root.x - center.x, root.z) - 0.57) < 0.00001)
            }
            precondition(simulation.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        }
        print("Piston simulation tests passed")
    }
}
