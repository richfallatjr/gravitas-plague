import Foundation
import simd

nonisolated struct MindEyeCompositeUniforms: Sendable, Equatable {
    var dimensions: SIMD4<UInt32>
    var cropAndFlags: SIMD4<UInt32>
    var backgroundTransform: SIMD4<Float>
    var characterTransform: SIMD4<Float>

    static func make(frame: MindEyeCompositeFrameState) -> MindEyeCompositeUniforms {
        MindEyeCompositeUniforms(
            dimensions: SIMD4<UInt32>(2_304, 1_296, 1_920, 1_080),
            cropAndFlags: SIMD4<UInt32>(
                192,
                108,
                frame.maskMode.rawValue,
                0
            ),
            backgroundTransform: SIMD4<Float>(
                frame.backgroundTransform.translationPixels.x,
                frame.backgroundTransform.translationPixels.y,
                frame.backgroundTransform.rollRadians,
                frame.backgroundTransform.scale
            ),
            characterTransform: SIMD4<Float>(
                frame.characterTransform.translationPixels.x,
                frame.characterTransform.translationPixels.y,
                frame.characterTransform.rollRadians,
                frame.characterTransform.scale
            )
        )
    }
}
