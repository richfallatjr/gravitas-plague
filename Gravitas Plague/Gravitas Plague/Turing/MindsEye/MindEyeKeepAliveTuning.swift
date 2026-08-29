import Foundation
import simd

nonisolated struct MindEyeResolvedBlinkTuning: Sendable, Equatable {
    let ordinaryIntervalSeconds: ClosedRange<Float>
    let closedReferenceFrames: ClosedRange<Int>
    let doubleBlinkProbability: Float
    let doubleBlinkGapSeconds: ClosedRange<Float>
    let referenceFrameRate: Float

    static let hardScheduleBounds: ClosedRange<Float> = 0.5...5.0
}

nonisolated struct MindEyeProjectionTuning: Sendable, Equatable {
    let outputSizePixels: SIMD2<Float>
    let horizontalFOVRadians: Float
    let driftRotationShare: Float
    let gripRotationShare: Float

    var focalPixels: Float {
        outputSizePixels.x / (2 * tan(horizontalFOVRadians * 0.5))
    }
}

nonisolated struct MindEyeKeepAliveTuning: Sendable, Equatable {
    let characterDepthMeters: Float
    let backgroundDepthMeters: Float
    let sharedDriftMaxPixels: SIMD2<Float>
    let sharedRollMaxRadians: Float
    let sharedScaleMax: Float
    let characterParallaxMaxPixels: SIMD2<Float>
    let characterScaleDeltaMax: Float
    let backgroundCounterMotion: Float
    let gripCorrectionMaxPixels: SIMD2<Float>
    let gripCorrectionMaxRadians: Float
    let driftTransitionSeconds: ClosedRange<Float>
    let driftHoldSeconds: ClosedRange<Float>
    let subjectTransitionSeconds: ClosedRange<Float>
    let subjectHoldSeconds: ClosedRange<Float>
    let gripWaitingSeconds: ClosedRange<Float>
    let gripOnsetSeconds: ClosedRange<Float>
    let gripSettleSeconds: ClosedRange<Float>
    let maximumSimulationStepSeconds: Float
    let blink: MindEyeResolvedBlinkTuning
    let projection: MindEyeProjectionTuning
    let openEyeVariantCount: Int
    let closedEyeVariantCount: Int
}

nonisolated enum MindEyeKeepAliveTuningResolver {
    static func resolve(
        package: MindEyeAssetPackage
    ) -> Result<MindEyeKeepAliveTuning, MindEyeFailure> {
        let authoredMotion = package.manifest.motion
        let authoredBlink = package.manifest.blink
        let tuning = MindEyeKeepAliveTuning(
            characterDepthMeters: package.manifest.depth.cameraToCharacterMeters,
            backgroundDepthMeters: package.manifest.depth.cameraToBackgroundMeters,
            sharedDriftMaxPixels: SIMD2<Float>(
                authoredMotion.sharedDriftMaxPixels.x,
                authoredMotion.sharedDriftMaxPixels.y
            ),
            sharedRollMaxRadians: authoredMotion.sharedRollMaxDegrees * .pi / 180,
            sharedScaleMax: authoredMotion.sharedScaleMax,
            characterParallaxMaxPixels: SIMD2<Float>(
                authoredMotion.characterParallaxMaxPixels.x,
                authoredMotion.characterParallaxMaxPixels.y
            ),
            characterScaleDeltaMax: 0.003,
            backgroundCounterMotion: authoredMotion.backgroundCounterMotion,
            gripCorrectionMaxPixels: SIMD2<Float>(
                authoredMotion.gripCorrectionMaxPixels.x,
                authoredMotion.gripCorrectionMaxPixels.y
            ),
            gripCorrectionMaxRadians: authoredMotion.gripCorrectionMaxDegrees * .pi / 180,
            driftTransitionSeconds: 0.9...2.6,
            driftHoldSeconds: 0...0.8,
            subjectTransitionSeconds: 1.2...3.8,
            subjectHoldSeconds: 0...1.0,
            gripWaitingSeconds: 7...18,
            gripOnsetSeconds: 0.18...0.35,
            gripSettleSeconds: 0.6...1.2,
            maximumSimulationStepSeconds: 1 / 15,
            blink: MindEyeResolvedBlinkTuning(
                ordinaryIntervalSeconds:
                    Float(authoredBlink.ordinaryIntervalMinSeconds)...Float(authoredBlink.ordinaryIntervalMaxSeconds),
                closedReferenceFrames:
                    authoredBlink.closedFrameMin...authoredBlink.closedFrameMax,
                doubleBlinkProbability: Float(authoredBlink.doubleBlinkProbability),
                doubleBlinkGapSeconds:
                    Float(authoredBlink.doubleBlinkGapMinSeconds)...Float(authoredBlink.doubleBlinkGapMaxSeconds),
                referenceFrameRate: 60
            ),
            projection: MindEyeProjectionTuning(
                outputSizePixels: MindEyeCompositeGeometry.outputSize,
                horizontalFOVRadians: 62 * .pi / 180,
                driftRotationShare: 0.72,
                gripRotationShare: 0.55
            ),
            openEyeVariantCount: package.eyes.open.count,
            closedEyeVariantCount: package.eyes.closed.count
        )
        if let failure = validate(tuning, package: package) {
            return .failure(failure)
        }
        return .success(tuning)
    }

    private static func validate(
        _ tuning: MindEyeKeepAliveTuning,
        package: MindEyeAssetPackage
    ) -> MindEyeFailure? {
        let values: [Float] = [
            tuning.characterDepthMeters,
            tuning.backgroundDepthMeters,
            tuning.sharedDriftMaxPixels.x,
            tuning.sharedDriftMaxPixels.y,
            tuning.sharedRollMaxRadians,
            tuning.sharedScaleMax,
            tuning.characterParallaxMaxPixels.x,
            tuning.characterParallaxMaxPixels.y,
            tuning.characterScaleDeltaMax,
            tuning.backgroundCounterMotion,
            tuning.gripCorrectionMaxPixels.x,
            tuning.gripCorrectionMaxPixels.y,
            tuning.gripCorrectionMaxRadians,
            tuning.maximumSimulationStepSeconds,
            tuning.projection.horizontalFOVRadians,
            tuning.projection.driftRotationShare,
            tuning.projection.gripRotationShare,
            tuning.blink.doubleBlinkProbability,
            tuning.blink.referenceFrameRate
        ]
        let nonnegativeMaxima = [
            tuning.sharedDriftMaxPixels.x,
            tuning.sharedDriftMaxPixels.y,
            tuning.sharedRollMaxRadians,
            tuning.characterParallaxMaxPixels.x,
            tuning.characterParallaxMaxPixels.y,
            tuning.characterScaleDeltaMax,
            tuning.gripCorrectionMaxPixels.x,
            tuning.gripCorrectionMaxPixels.y,
            tuning.gripCorrectionMaxRadians
        ]
        let ranges = [
            tuning.driftTransitionSeconds,
            tuning.driftHoldSeconds,
            tuning.subjectTransitionSeconds,
            tuning.subjectHoldSeconds,
            tuning.gripWaitingSeconds,
            tuning.gripOnsetSeconds,
            tuning.gripSettleSeconds,
            tuning.blink.ordinaryIntervalSeconds,
            tuning.blink.doubleBlinkGapSeconds
        ]
        let fovDegrees = tuning.projection.horizontalFOVRadians * 180 / .pi
        let valid = values.allSatisfy(\.isFinite) &&
            nonnegativeMaxima.allSatisfy { $0 >= 0 } &&
            ranges.allSatisfy {
                $0.lowerBound.isFinite && $0.upperBound.isFinite &&
                    $0.lowerBound >= 0 && $0.lowerBound <= $0.upperBound
            } &&
            tuning.characterDepthMeters > 0 &&
            tuning.backgroundDepthMeters > tuning.characterDepthMeters &&
            fovDegrees > 20 && fovDegrees < 120 &&
            tuning.sharedRollMaxRadians <= 2 * .pi / 180 &&
            (1...1.05).contains(tuning.sharedScaleMax) &&
            (0.20...0.35).contains(tuning.backgroundCounterMotion) &&
            tuning.gripCorrectionMaxRadians <= .pi / 180 &&
            tuning.driftTransitionSeconds.lowerBound > 0 &&
            tuning.subjectTransitionSeconds.lowerBound > 0 &&
            tuning.gripWaitingSeconds.lowerBound > 0 &&
            tuning.gripOnsetSeconds.lowerBound > 0 &&
            tuning.gripSettleSeconds.lowerBound > 0 &&
            tuning.maximumSimulationStepSeconds > 0 &&
            tuning.blink.ordinaryIntervalSeconds.lowerBound >= 0.5 &&
            tuning.blink.ordinaryIntervalSeconds.upperBound <= 5 &&
            tuning.blink.closedReferenceFrames.lowerBound >= 1 &&
            tuning.blink.closedReferenceFrames.upperBound <= 20 &&
            (0...1).contains(tuning.blink.doubleBlinkProbability) &&
            tuning.blink.doubleBlinkGapSeconds.lowerBound >= 0.5 &&
            tuning.blink.doubleBlinkGapSeconds.upperBound <= 5 &&
            tuning.openEyeVariantCount >= 1
        guard valid else {
            return MindEyeFailure(
                code: .invalidMotionTuning,
                characterID: package.characterID,
                vignetteID: package.vignetteID,
                resourcePath: nil,
                message: "Mind's Eye motion or blink tuning is invalid."
            )
        }
        return nil
    }
}
