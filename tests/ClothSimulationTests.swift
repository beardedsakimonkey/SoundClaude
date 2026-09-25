import Foundation
import simd

@main
struct ClothSimulationTests {
    // Small isolated constraints verify XPBD independently of the full mesh.
    static func checkXPBD() {
        func step(_ positions: inout [SIMD4<Float>], edges: inout [SCClothEdge],
                  bends: inout [SCClothBend], compliance: Float, bendCompliance: Float,
                  iterations: UInt32) {
            // Keep the bottom pins outside the isolated constraints.
            positions.append(contentsOf: [.zero, .zero])
            defer { positions.removeLast(2) }
            var previous = positions // Start at rest to isolate constraint corrections.
            let edgeCount = UInt32(edges.count), bendCount = UInt32(bends.count)
            let rows = UInt32(positions.count / 2)
            positions.withUnsafeMutableBufferPointer { p in
                previous.withUnsafeMutableBufferPointer { old in
                    edges.withUnsafeMutableBufferPointer { e in
                        bends.withUnsafeMutableBufferPointer { b in
                            SCClothStep(p.baseAddress!, old.baseAddress!, 2, rows,
                                        e.baseAddress, edgeCount, b.baseAddress, bendCount,
                                        0, compliance, bendCompliance, 0, iterations)
                        }
                    }
                }
            }
        }
        for compliance: Float in [0, 0.00001, 0.001] {
            for iterations: UInt32 in [1, 8] {
                var p: [SIMD4<Float>] = [.zero, SIMD4(1, 0, 0, 0), SIMD4(0, 2, 0, 0), .zero]
                var edges = [SCClothEdge(a: 0, b: 2, rest: 1, aWeight: 0, bWeight: 1, lambda: 99)]
                var bends: [SCClothBend] = []
                let alpha = compliance * 120 * 120
                step(&p, edges: &edges, bends: &bends, compliance: compliance,
                     bendCompliance: 0, iterations: iterations)
                let residual = alpha / (1 + alpha)
                precondition(abs(p[2].y - (1 + residual)) < 0.00001,
                             "XPBD compliance must not vanish with more passes")
                precondition(p[0] == .zero)
                step(&p, edges: &edges, bends: &bends, compliance: compliance,
                     bendCompliance: 0, iterations: iterations)
                precondition(abs(p[2].y - (1 + residual * residual)) < 0.00001,
                             "Multipliers must reset each time step")
            }
        }
        func angle(_ p: [SIMD4<Float>]) -> Float {
            func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
            let e = xyz(p[1] - p[0])
            let n1 = simd_normalize(simd_cross(e, xyz(p[2] - p[0])))
            let n2 = simd_normalize(simd_cross(xyz(p[3] - p[0]), e))
            return atan2(simd_dot(simd_cross(n1, n2), simd_normalize(e)), simd_dot(n1, n2))
        }
        // Check all four analytic gradients against numerical angle derivatives,
        // including the two moving hinge endpoints and a nonzero rest angle.
        var hinge: [SIMD4<Float>] = [SIMD4(0.2, 0.1, -0.1, 0), SIMD4(1.1, 0.3, 0.2, 0),
                                    SIMD4(0.3, 1.2, 0.4, 0), SIMD4(0.8, -0.7, 0.6, 0)]
        let epsilon: Float = 0.001
        var gradients = Array(repeating: SIMD4<Float>.zero, count: 4)
        for i in 0..<4 {
            for axis in 0..<3 {
                var plus = hinge, minus = hinge
                plus[i][axis] += epsilon
                minus[i][axis] -= epsilon
                gradients[i][axis] = (angle(plus) - angle(minus)) / (2 * epsilon)
            }
        }
        let alpha: Float = 0.001 * 14400
        let delta = (-(angle(hinge) - 0.2)) / (gradients.reduce(alpha) { $0 + simd_length_squared($1) })
        let expected = zip(hinge, gradients).map { $0 + $1 * delta }
        hinge.insert(contentsOf: [.zero, .zero], at: 0) // Pins are outside this hinge.
        var noEdges: [SCClothEdge] = []
        var hingeBends = [SCClothBend(a: 2, b: 3, c: 4, d: 5, restAngle: 0.2, lambda: 0)]
        step(&hinge, edges: &noEdges, bends: &hingeBends, compliance: 0, bendCompliance: 0.001, iterations: 1)
        precondition(zip(hinge.dropFirst(2), expected).allSatisfy { simd_distance($0, $1) < 0.0001 },
                     "Dihedral corrections must match the angle gradient")

        for fold: Float in [-2.8, -0.8, 0, 0.8, 2.8] {
            for compliance: Float in [0, 0.01] {
                var p: [SIMD4<Float>] = [.zero, SIMD4(1, 0, 0, 0),
                                         SIMD4(0, 1, 0, 0), SIMD4(1, -cos(fold), sin(fold), 0)]
                let initial = p
                var edges: [SCClothEdge] = []
                var bends = [SCClothBend(a: 0, b: 1, c: 2, d: 3, restAngle: 0, lambda: 99)]
                step(&p, edges: &edges, bends: &bends, compliance: 0,
                     bendCompliance: compliance, iterations: 20)
                precondition(p[0] == initial[0] && p[1] == initial[1], "Bending must preserve pins")
                precondition(p.allSatisfy { simd_length($0).isFinite })
                precondition(abs(angle(p)) <= abs(fold) + 0.00001)
                precondition(abs(angle(p) + compliance * 14400 * bends[0].lambda) < 0.0001,
                             "Signed dihedral constraints must reach compliant equilibrium")
                if compliance == 0 { precondition(abs(angle(p)) < 0.0001) }
                if compliance > 0 && fold != 0 { precondition(abs(angle(p)) > 0.1) }
            }
        }
        for p0: [SIMD4<Float>] in [Array(repeating: .zero, count: 4),
                                   [.zero, SIMD4(1, 0, 0, 0), SIMD4(2, 0, 0, 0), SIMD4(0, 1, 0, 0)]] {
            var p = p0
            var edges: [SCClothEdge] = []
            var bends = [SCClothBend(a: 0, b: 1, c: 2, d: 3, restAngle: 0, lambda: 0)]
            step(&p, edges: &edges, bends: &bends, compliance: 0, bendCompliance: 0, iterations: 8)
            precondition(p == p0, "Degenerate hinges must be skipped safely")
        }
    }

    static func main() {
        checkXPBD()
        // Bass flashes restart on each hit and expire by elapsed time, even
        // when the physics catch-up limit skips time after a suspended frame.
        var flashing = ClothSimulation()
        precondition(flashing.bassPulse == 0)
        flashing.impulse(strength: 0.3)
        precondition(flashing.bassPulse == 1 && flashing.bassPulseLevel == 0.3)
        var fasterFlash = flashing
        flashing.advance(delta: 1 / 30)
        for _ in 0..<4 { fasterFlash.advance(delta: 1 / 120) }
        precondition(abs(flashing.bassPulse - fasterFlash.bassPulse) < 0.00001)
        flashing.impulse(strength: 0.9)
        precondition(flashing.bassPulse == 1 && flashing.bassPulseLevel == 0.9)
        flashing.advance(delta: 0.4)
        precondition(flashing.bassPulse == 0)
        var trebleDetector = ClothBassDetector.treble
        for _ in 0..<60 { precondition(trebleDetector.update(level: 0, delta: 1 / 60) == nil) }
        precondition(trebleDetector.update(level: 0.01, delta: 1 / 60) != nil,
                     "Treble floor zero must allow quiet transients")
        _ = trebleDetector.update(level: 0, delta: 0.1)
        precondition(trebleDetector.update(level: 0.02, delta: 0.1) == nil)
        _ = trebleDetector.update(level: 0, delta: 0.1)
        precondition(trebleDetector.update(level: 0.03, delta: 0.05) != nil)
        var steadyTreble = ClothBassDetector.treble
        for _ in 0..<60 { _ = steadyTreble.update(level: 0.01, delta: 1 / 60) }
        precondition(steadyTreble.update(level: 0.015, delta: 1 / 60) == nil,
                     "Treble must exceed three times the recent mean energy")
        var trebleSettings = ClothSettings()
        trebleSettings.gravity = 0
        trebleSettings.iterations = 0
        var trebleCloth = ClothSimulation(settings: trebleSettings)
        let trebleRest = trebleCloth.positions
        trebleCloth.trebleImpulse(strength: 1)
        let origin = trebleCloth.trebleOrigin
        let ringRadius = simd_length(origin / SIMD2(trebleSettings.width / 2, trebleSettings.height / 2))
        precondition(ringRadius >= 0.72 && ringRadius <= 0.88)
        precondition(trebleCloth.treblePulse == 1 && trebleCloth.bassPulse == 0)
        precondition(trebleCloth.nextTrebleDirection == -1 && trebleCloth.nextDirection == 1)
        trebleCloth.advance(delta: ClothSimulation.step)
        let nearest = trebleRest.indices.min {
            simd_distance(SIMD2(trebleRest[$0].x, trebleRest[$0].y), origin) <
            simd_distance(SIMD2(trebleRest[$1].x, trebleRest[$1].y), origin)
        }!
        precondition(trebleCloth.positions[nearest].z > 0.1)
        for i in trebleRest.indices where trebleCloth.isPinned(i) {
            precondition(trebleCloth.positions[i] == trebleRest[i])
        }
        trebleCloth.advance(delta: 0.2)
        precondition(trebleCloth.treblePulse == 0)
        trebleCloth.trebleImpulse(strength: 0.5)
        precondition(trebleCloth.trebleOrigin != origin && trebleCloth.nextTrebleDirection == 1)
        var rippleCloth = ClothSimulation(settings: trebleSettings)
        rippleCloth.impulse(strength: 1)
        rippleCloth.advance(delta: 1)
        rippleCloth.trebleImpulse(strength: 0.5)
        precondition(rippleCloth.ripples.count == 2)
        precondition(rippleCloth.ripples[0].age == 1,
                     "New hits must not restart an older ripple")
        precondition(!rippleCloth.ripples[0].isTreble && rippleCloth.ripples[1].isTreble)
        rippleCloth.advance(delta: Double(ClothSimulation.rippleLifetime) - 1.5)
        precondition(rippleCloth.ripples.count == 2,
                     "Ripples must remain active while crossing the cloth")
        rippleCloth.advance(delta: 0.5)
        precondition(rippleCloth.ripples.count == 1 && rippleCloth.ripples[0].isTreble,
                     "Each ripple must expire on its own")
        rippleCloth.advance(delta: 1)
        precondition(rippleCloth.ripples.isEmpty)
        for _ in 0..<(ClothSimulation.maximumRipples + 10) { rippleCloth.impulse(strength: 1) }
        precondition(rippleCloth.ripples.count == ClothSimulation.maximumRipples,
                     "Repeated hits must stay within the shader capacity")
        rippleCloth.configure(ClothSettings())
        precondition(rippleCloth.ripples.count == ClothSimulation.maximumRipples)
        var cloth = ClothSimulation()
        let initial = cloth.positions
        let center = initial.count / 2
        cloth.impulse(strength: 0.7)
        cloth.advance(delta: ClothSimulation.step)
        precondition(cloth.positions[center].z > 0)
        precondition(cloth.nextDirection == -1)
        cloth.impulse(strength: 0.7)
        precondition(cloth.nextDirection == 1)
        for frame in 0..<1200 {
            if frame % 30 == 0 { cloth.impulse(strength: 1) }
            cloth.advance(delta: 1 / 60)
        }
        for i in initial.indices {
            if cloth.isPinned(i) { precondition(cloth.positions[i] == initial[i]) }
            precondition(cloth.positions[i].x.isFinite && cloth.positions[i].y.isFinite && cloth.positions[i].z.isFinite)
            precondition(simd_length(cloth.positions[i]) < 10)
        }
        var slow = ClothSimulation()
        slow.impulse(strength: 1)
        var fast = slow // Compare frame rates with the same random impulse.
        for _ in 0..<60 { slow.advance(delta: 1 / 60) }
        for _ in 0..<120 { fast.advance(delta: 1 / 120) }
        precondition(zip(slow.positions, fast.positions).allSatisfy { simd_distance($0, $1) < 0.0001 })
        var settings = ClothSettings()
        settings.columns = 17
        settings.rows = 23
        settings.width = 8
        settings.height = 3
        cloth.configure(settings)
        precondition(cloth.positions.count == 17 * 23)
        precondition(cloth.positions.first! == SIMD4(-4, 1.5, 0, 0))
        precondition(cloth.positions.last! == SIMD4(4, -1.5, 0, 0))
        let corners = cloth.positions.indices.filter { cloth.isPinned($0) }
        precondition(corners == [0, cloth.columns - 1, cloth.positions.count - cloth.columns,
                                 cloth.positions.count - 1])
        let pins = corners.map { cloth.positions[$0] }
        cloth.impulse(strength: 1)
        cloth.advance(delta: 1 / 60)
        let deformed = cloth.positions
        settings.damping = 0.05
        settings.compliance = 0.000001
        settings.bendCompliance = 0.02
        cloth.configure(settings)
        precondition(cloth.positions == deformed, "Motion settings must not reset the mesh")
        for _ in 0..<120 { cloth.advance(delta: 1 / 60) }
        precondition(corners.map { cloth.positions[$0] } == pins)
        // Gravity moves the interior while all four corners stay pinned.
        var hanging = ClothSimulation(settings: settings)
        let resting = hanging.positions
        hanging.advance(delta: ClothSimulation.step)
        let hangingCenter = resting.count / 2
        precondition(hanging.positions[hangingCenter].z > resting[hangingCenter].z,
                     "Gravity must pull toward the default camera along positive Z")
        precondition(abs(hanging.positions[hangingCenter].y - resting[hangingCenter].y) < 0.00001,
                     "Gravity must not pull down along Y")
        for _ in 0..<60 { hanging.advance(delta: 1 / 60) }
        let bottomCenter = resting.count - hanging.columns + hanging.columns / 2
        precondition(hanging.positions[bottomCenter].z > resting[bottomCenter].z,
                     "The bottom edge between the pins must respond to gravity")
        for index in corners {
            precondition(hanging.positions[index] == resting[index])
        }
        settings.impulseStrength = 0
        settings.gravity = 0
        var silent = ClothSimulation(settings: settings)
        silent.impulse(strength: 1)
        silent.advance(delta: 1 / 60)
        precondition(silent.positions.allSatisfy { $0.z == 0 })
        var directionSettings = ClothSettings()
        directionSettings.gravity = 0
        directionSettings.iterations = 0
        let flat = ClothSimulation(settings: directionSettings).positions
        // With gravity and constraints disabled, measure the impulse direction.
        // Copy the unadvanced state to isolate each hit's contribution.
        for _ in 0..<20 {
            var scattered = ClothSimulation(settings: directionSettings)
            scattered.impulse(strength: 1)
            var firstHit = scattered
            firstHit.advance(delta: ClothSimulation.step)
            let firstMotion = firstHit.positions[center] - flat[center]
            let tilt = simd_length(SIMD2(firstMotion.x, firstMotion.y)) / simd_length(firstMotion)
            precondition(tilt >= 0.108 - 0.00001 && tilt <= 0.24 + 0.00001)
            precondition(firstMotion.z > 0)
            let hitOrigin = scattered.ripples[0].origin
            let centerOffset = SIMD2(flat[center].x, flat[center].y) - hitOrigin
            let centerFalloff = exp(-simd_length_squared(centerOffset)
                                    / (directionSettings.impulseRadius * directionSettings.impulseRadius))
            precondition(abs(simd_length(firstMotion) - 0.165 * directionSettings.impulseStrength
                             * centerFalloff * (1 - directionSettings.damping)) < 0.00001,
                         "Scatter must preserve impulse strength around the visual ripple origin")
            scattered.impulse(strength: 1)
            scattered.advance(delta: ClothSimulation.step)
            let secondMotion = scattered.positions[center] - flat[center] - firstMotion
            precondition(secondMotion.z < 0, "Scattered hits must alternate depth direction")
        }
        var detector = ClothBassDetector()
        for _ in 0..<60 { precondition(detector.update(level: 0, delta: 1 / 60) == nil) }
        precondition(detector.update(level: 0.7, delta: 1 / 60) != nil)
        for _ in 0..<120 { precondition(detector.update(level: 0.7, delta: 1 / 60) == nil) }
        for _ in 0..<30 { _ = detector.update(level: 0.05, delta: 1 / 60) }
        precondition(detector.update(level: 0.8, delta: 1 / 60) != nil)
        precondition(detector.update(level: .nan, delta: 1 / 60) == nil)
        // A small rise above the energy threshold must trigger. The old
        // minimum-rise condition missed these gradual bass attacks.
        var gradual = ClothBassDetector()
        for _ in 0..<60 { _ = gradual.update(level: 0.1, delta: 1 / 60) }
        var gradualHits = 0
        for step in 1...30 {
            if gradual.update(level: 0.1 + Float(step) * 0.005, delta: 1 / 60) != nil {
                gradualHits += 1
            }
        }
        precondition(gradualHits > 0)

        var repeatHits = ClothBassDetector()
        for _ in 0..<60 { _ = repeatHits.update(level: 0.1, delta: 1 / 60) }
        precondition(repeatHits.update(level: 0.3, delta: 1 / 60) != nil)
        _ = repeatHits.update(level: 0.29, delta: 0.1)
        precondition(repeatHits.update(level: 0.31, delta: 0.1) == nil,
                     "The cooldown must suppress closely spaced hits")
        precondition(repeatHits.update(level: 0.32, delta: 0.1) != nil,
                     "A rising hit after cooldown must not require re-arming")
        precondition(repeatHits.update(level: 0.5, delta: 2) == nil,
                     "Expired history must not trigger a hit after a long gap")
        var quiet = ClothBassDetector()
        for _ in 0..<60 { _ = quiet.update(level: 0, delta: 1 / 60) }
        precondition(quiet.update(level: 0.04, delta: 1 / 60) == nil)
        // Live playback had a background near 0.003 and bass peaks near
        // 0.015: the old 0.02 floor suppressed every hit in that range.
        var capturedBass = ClothBassDetector()
        for _ in 0..<60 { _ = capturedBass.update(level: sqrt(0.003), delta: 1 / 60) }
        let capturedHit = capturedBass.update(level: sqrt(0.015), delta: 1 / 60)
        precondition(capturedHit != nil, "Quiet playback bass peaks must trigger")
        var capturedCloth = ClothSimulation()
        capturedCloth.impulse(strength: capturedHit!)
        capturedCloth.advance(delta: 1 / 60)
        precondition(capturedCloth.bassPulse > 0.9 && capturedCloth.bassPulseLevel > 0)
        print("Cloth simulation tests passed")
    }
}
