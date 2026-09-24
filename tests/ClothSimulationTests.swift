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
        var slow = ClothSimulation(), fast = ClothSimulation()
        slow.impulse(strength: 1)
        fast.impulse(strength: 1)
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
        precondition(corners.count == 4)
        let pins = corners.map { cloth.positions[$0] }
        cloth.impulse(strength: 1)
        cloth.advance(delta: 1 / 60)
        let deformed = cloth.positions
        settings.damping = 0.05
        cloth.configure(settings)
        precondition(cloth.positions == deformed, "Motion settings must not reset the mesh")
        for _ in 0..<120 { cloth.advance(delta: 1 / 60) }
        precondition(corners.map { cloth.positions[$0] } == pins)
        settings.impulseStrength = 0
        var silent = ClothSimulation(settings: settings)
        silent.impulse(strength: 1)
        silent.advance(delta: 1 / 60)
        precondition(silent.positions.allSatisfy { $0.z == 0 })
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
