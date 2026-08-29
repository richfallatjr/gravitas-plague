import Foundation
import simd

nonisolated struct MindEyeVirtualCameraPose: Sendable, Equatable {
    var translationMeters: SIMD3<Float>
    var yawRadians: Float
    var pitchRadians: Float
    var rollRadians: Float

    static let identity = MindEyeVirtualCameraPose(
        translationMeters: .zero,
        yawRadians: 0,
        pitchRadians: 0,
        rollRadians: 0
    )
}

nonisolated struct MindEyeSubjectRelativePose: Sendable, Equatable {
    var translationMeters: SIMD2<Float>
    var scaleDelta: Float

    static let identity = MindEyeSubjectRelativePose(
        translationMeters: .zero,
        scaleDelta: 0
    )
}

nonisolated struct MindEyeSelfieProjectionResult: Sendable, Equatable {
    let backgroundTransform: MindEyeLayerTransform
    let characterTransform: MindEyeLayerTransform
    let foregroundTranslationPixels: SIMD2<Float>
    let backgroundTranslationPixels: SIMD2<Float>
    let subjectOffsetPixels: SIMD2<Float>
}

nonisolated enum MindEyeSelfieCameraPoseBuilder {
    static func make(
        driftNormalized: SIMD4<Float>,
        gripNormalized: SIMD3<Float>,
        tuning: MindEyeKeepAliveTuning
    ) -> MindEyeVirtualCameraPose {
        let focal = tuning.projection.focalPixels
        let depth = tuning.characterDepthMeters
        let driftPixels = SIMD2<Float>(
            driftNormalized.x,
            driftNormalized.y
        ) * tuning.sharedDriftMaxPixels
        let gripPixels = SIMD2<Float>(
            gripNormalized.x,
            gripNormalized.y
        ) * tuning.gripCorrectionMaxPixels
        let driftRotationPixels = driftPixels * tuning.projection.driftRotationShare
        let driftTranslationPixels = driftPixels - driftRotationPixels
        let gripRotationPixels = gripPixels * tuning.projection.gripRotationShare
        let gripTranslationPixels = gripPixels - gripRotationPixels
        let totalRotationPixels = driftRotationPixels + gripRotationPixels
        let totalTranslationPixels = driftTranslationPixels + gripTranslationPixels
        let desiredScale = 1 + min(1, max(0, driftNormalized.w)) *
            (tuning.sharedScaleMax - 1)
        return MindEyeVirtualCameraPose(
            translationMeters: SIMD3<Float>(
                -totalTranslationPixels.x * depth / focal,
                -totalTranslationPixels.y * depth / focal,
                desiredScale > 1 ? depth * (1 - 1 / desiredScale) : 0
            ),
            yawRadians: -atan(totalRotationPixels.x / focal),
            pitchRadians: -atan(totalRotationPixels.y / focal),
            rollRadians: -(
                driftNormalized.z * tuning.sharedRollMaxRadians +
                    gripNormalized.z * tuning.gripCorrectionMaxRadians
            )
        )
    }

    static func makeSubjectPose(
        subjectNormalized: SIMD3<Float>,
        tuning: MindEyeKeepAliveTuning
    ) -> MindEyeSubjectRelativePose {
        let desiredPixels = SIMD2<Float>(
            subjectNormalized.x,
            subjectNormalized.y
        ) * tuning.characterParallaxMaxPixels
        return MindEyeSubjectRelativePose(
            translationMeters: desiredPixels *
                tuning.characterDepthMeters / tuning.projection.focalPixels,
            scaleDelta: subjectNormalized.z * tuning.characterScaleDeltaMax
        )
    }
}

nonisolated enum MindEyeSelfieProjection {
    private static func projectCamera(
        _ camera: MindEyeVirtualCameraPose,
        depthMeters: Float,
        focalPixels: Float
    ) -> MindEyeLayerTransform {
        let safeDepth = max(0.05, depthMeters)
        let rotationShift = SIMD2<Float>(
            -focalPixels * tan(camera.yawRadians),
            -focalPixels * tan(camera.pitchRadians)
        )
        let translationShift = SIMD2<Float>(
            -focalPixels * camera.translationMeters.x / safeDepth,
            -focalPixels * camera.translationMeters.y / safeDepth
        )
        let denominator = max(0.05, safeDepth - camera.translationMeters.z)
        return MindEyeLayerTransform(
            translationPixels: rotationShift + translationShift,
            rollRadians: -camera.rollRadians,
            scale: safeDepth / denominator
        )
    }

    static func project(
        camera: MindEyeVirtualCameraPose,
        subject: MindEyeSubjectRelativePose,
        tuning: MindEyeKeepAliveTuning
    ) -> Result<MindEyeSelfieProjectionResult, MindEyeFailure> {
        let focal = tuning.projection.focalPixels
        guard focal.isFinite, focal > 0 else {
            return .failure(failure("Mind's Eye focal length is invalid."))
        }
        let foreground = projectCamera(
            camera,
            depthMeters: tuning.characterDepthMeters,
            focalPixels: focal
        )
        let backgroundCamera = projectCamera(
            camera,
            depthMeters: tuning.backgroundDepthMeters,
            focalPixels: focal
        )
        let subjectPixels = subject.translationMeters * focal /
            tuning.characterDepthMeters
        let character = MindEyeLayerTransform(
            translationPixels: foreground.translationPixels + subjectPixels,
            rollRadians: foreground.rollRadians,
            scale: foreground.scale * (1 + subject.scaleDelta)
        )
        let background = MindEyeLayerTransform(
            translationPixels: backgroundCamera.translationPixels -
                subjectPixels * tuning.backgroundCounterMotion,
            rollRadians: backgroundCamera.rollRadians,
            scale: backgroundCamera.scale
        )
        guard character.isFiniteAndPositive, background.isFiniteAndPositive else {
            return .failure(failure(
                "Mind's Eye selfie projection produced a nonfinite transform."
            ))
        }
        return .success(MindEyeSelfieProjectionResult(
            backgroundTransform: background,
            characterTransform: character,
            foregroundTranslationPixels: foreground.translationPixels,
            backgroundTranslationPixels: backgroundCamera.translationPixels,
            subjectOffsetPixels: subjectPixels
        ))
    }

    private static func failure(_ message: String) -> MindEyeFailure {
        MindEyeFailure(
            code: .invalidMotionProjection,
            characterID: nil,
            vignetteID: nil,
            resourcePath: nil,
            message: message
        )
    }
}
