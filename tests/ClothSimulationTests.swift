import Foundation
import simd

@main
struct ClothSimulationTests {
    static func main() {
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
        precondition(corners == [0, cloth.columns - 1])
        let pins = corners.map { cloth.positions[$0] }
        cloth.impulse(strength: 1)
        cloth.advance(delta: 1 / 60)
        let deformed = cloth.positions
        settings.damping = 0.05
        cloth.configure(settings)
        precondition(cloth.positions == deformed, "Motion settings must not reset the mesh")
        for _ in 0..<120 { cloth.advance(delta: 1 / 60) }
        precondition(corners.map { cloth.positions[$0] } == pins)
        // Both bottom corners must respond to gravity without an audio impulse.
        var hanging = ClothSimulation(settings: settings)
        let resting = hanging.positions
        for _ in 0..<60 { hanging.advance(delta: 1 / 60) }
        for index in [resting.count - hanging.columns, resting.count - 1] {
            precondition(hanging.positions[index].y < resting[index].y,
                         "The bottom corners must hang freely")
        }
        for index in [0, hanging.columns - 1] {
            precondition(hanging.positions[index] == resting[index])
        }
        settings.impulseStrength = 0
        var silent = ClothSimulation(settings: settings)
        silent.impulse(strength: 1)
        silent.advance(delta: 1 / 60)
        precondition(silent.positions.allSatisfy { $0.z == 0 })
        // Pointer movement affects a local region and preserves the pinned corners.
        var brushSettings = ClothSettings()
        brushSettings.gravity = 0
        var brushed = ClothSimulation(settings: brushSettings)
        let flat = brushed.positions
        let camera = ClothCamera(yaw: 0, pitch: 0, zoom: 0.8)
        brushed.brush(from: .zero, to: .zero, camera: camera, aspect: 1)
        brushed.advance(delta: ClothSimulation.step)
        precondition(brushed.positions == flat, "A stationary pointer must not add force")
        brushed.brush(from: SIMD2(-0.1, 0), to: SIMD2(0.1, 0), camera: camera, aspect: 1)
        brushed.advance(delta: ClothSimulation.step)
        precondition(brushed.positions[center].z < -0.01, "The brush must push the cloth")
        precondition(abs(brushed.positions[brushSettings.columns + 1].z) < 0.001,
                     "The brush must remain local")
        for i in flat.indices where brushed.isPinned(i) { precondition(brushed.positions[i] == flat[i]) }
        var missed = ClothSimulation(settings: brushSettings)
        missed.brush(from: SIMD2(0.98, 0.98), to: SIMD2(1, 1), camera: camera, aspect: 1)
        missed.advance(delta: ClothSimulation.step)
        precondition(missed.positions == flat, "Movement away from the cloth must not deform it")
        // Isolate the brush force from constraint corrections. Camera rotation
        // must not turn the push away from the resting cloth's plane normal.
        var directionSettings = brushSettings
        directionSettings.stiffness = 0
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
            precondition(abs(simd_length(firstMotion) - 0.165 * (1 - directionSettings.damping)) < 0.00001,
                         "Scatter must preserve impulse strength")
            scattered.impulse(strength: 1)
            scattered.advance(delta: ClothSimulation.step)
            let secondMotion = scattered.positions[center] - flat[center] - firstMotion
            precondition(secondMotion.z < 0, "Scattered hits must alternate depth direction")
        }
        for angle: Float in [0, 0.7, .pi / 2, .pi] {
            var rotated = ClothSimulation(settings: directionSettings)
            rotated.brush(from: SIMD2(-0.1, 0), to: SIMD2(0.1, 0),
                          camera: ClothCamera(yaw: angle, pitch: 0.4, zoom: 0.8), aspect: 0.5)
            rotated.advance(delta: ClothSimulation.step)
            precondition(rotated.positions[center].z < -0.01,
                         "The push must follow the cloth plane normal at every camera angle")
            for i in flat.indices {
                precondition(rotated.positions[i].x == flat[i].x && rotated.positions[i].y == flat[i].y,
                             "The brush must not add force along the cloth plane")
            }
        }
        for frame in 0..<240 {
            let x = Float(sin(Double(frame) * 0.2)) * 0.5
            brushed.brush(from: SIMD2(x, -0.05), to: SIMD2(x, 0.05), camera: camera, aspect: 1)
            brushed.advance(delta: 1 / 60)
        }
        precondition(brushed.positions.allSatisfy { simd_length($0).isFinite && simd_length($0) < 10 })
        var detector = ClothBassDetector()
        for _ in 0..<60 { precondition(detector.update(level: 0, delta: 1 / 60) == nil) }
        precondition(detector.update(level: 0.7, delta: 1 / 60) != nil)
        for _ in 0..<120 { precondition(detector.update(level: 0.7, delta: 1 / 60) == nil) }
        for _ in 0..<30 { _ = detector.update(level: 0.05, delta: 1 / 60) }
        precondition(detector.update(level: 0.8, delta: 1 / 60) != nil)
        precondition(detector.update(level: .nan, delta: 1 / 60) == nil)
        print("Cloth simulation tests passed")
    }
}
