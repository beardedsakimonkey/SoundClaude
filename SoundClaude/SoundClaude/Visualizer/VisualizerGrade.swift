import Foundation
import simd

/// Final color grade applied to the whole piston frame, backdrop included.
struct VisualizerGrade: Equatable {
    var amount: Float = 1 // Blend between the ungraded and graded frame.
    var contrast: Float = 1 // S-curve slope around mid gray; 1 is neutral.
    var saturation: Float = 1
    var shadowTint = SIMD3<Float>(0.72, 0.9, 1.0) // Linear RGB; white is neutral.
    var highlightTint = SIMD3<Float>(1.0, 0.86, 0.7) // Linear RGB; white is neutral.
    var vignette: Float = 0.5
    var grain: Float = 0.03

    static let pistons = VisualizerGrade()

    static func sRGBEncoded(_ linear: SIMD3<Float>) -> SIMD3<Float> {
        func encode(_ c: Float) -> Float {
            c <= 0.0031308 ? max(0, c) * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return SIMD3(encode(linear.x), encode(linear.y), encode(linear.z))
    }
}
