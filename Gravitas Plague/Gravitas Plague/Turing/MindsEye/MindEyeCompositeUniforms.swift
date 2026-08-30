import Foundation
import simd

nonisolated struct MindEyeCompositeUniforms: Sendable, Equatable {
    var dimensions: SIMD4<UInt32>
    var cropAndFlags: SIMD4<UInt32>
    var backgroundTransform: SIMD4<Float>
    var characterTransform: SIMD4<Float>

    static func make(
        frame: MindEyeCompositeFrameState,
        canvasProfile: MindEyeCompositorCanvasProfile = .landscapePortraitCard
    ) -> MindEyeCompositeUniforms {
        let source = canvasProfile.sourceDimensions
        let output = canvasProfile.outputDimensions
        let crop = canvasProfile.cropOrigin
        let backgroundTransform = canvasProfile.permitsInternalMotion
            ? frame.backgroundTransform
            : .identity
        let characterTransform = canvasProfile.permitsInternalMotion
            ? frame.characterTransform
            : .identity
        return MindEyeCompositeUniforms(
            dimensions: SIMD4<UInt32>(
                UInt32(source.x), UInt32(source.y),
                UInt32(output.x), UInt32(output.y)
            ),
            cropAndFlags: SIMD4<UInt32>(
                UInt32(crop.x),
                UInt32(crop.y),
                frame.maskMode.rawValue,
                0
            ),
            backgroundTransform: SIMD4<Float>(
                backgroundTransform.translationPixels.x,
                backgroundTransform.translationPixels.y,
                backgroundTransform.rollRadians,
                backgroundTransform.scale
            ),
            characterTransform: SIMD4<Float>(
                characterTransform.translationPixels.x,
                characterTransform.translationPixels.y,
                characterTransform.rollRadians,
                characterTransform.scale
            )
        )
    }
}
