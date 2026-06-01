import Foundation
import simd

struct PhaseOneConfiguration: Equatable {
    let farDistance: Float
    let nearDistance: Float

    let fallbackHeadToFloorOffset: Float
    let floorDetectionTimeoutSeconds: TimeInterval

    let idleFarDuration: TimeInterval
    let idleNearDuration: TimeInterval
    let turnRightDuration: TimeInterval

    let walkSpeedMetersPerSecond: Float
    let walkStopEpsilon: Float

    let rootScale: SIMD3<Float>

    let rootYawOffsetRadians: Float

    let visualPitchCorrectionRadians: Float
    let visualYawCorrectionRadians: Float
    let visualRollCorrectionRadians: Float

    let autoAlignVisualBottomToGround: Bool

    let clipTransitionDuration: TimeInterval
    let loopedAnimationRepeatDuration: TimeInterval

    let animationCompletionTolerance: TimeInterval
    let logClipDurations: Bool

    static let phaseOneDefault = PhaseOneConfiguration(
        farDistance: 3.05,
        nearDistance: 1.55,

        fallbackHeadToFloorOffset: -1.45,
        floorDetectionTimeoutSeconds: 1.75,

        idleFarDuration: 2.0,
        idleNearDuration: 2.0,
        turnRightDuration: 1.2,

        walkSpeedMetersPerSecond: 0.40,
        walkStopEpsilon: 0.025,

        rootScale: SIMD3<Float>(1, 1, 1),

        rootYawOffsetRadians: 0,

        visualPitchCorrectionRadians: 0,
        visualYawCorrectionRadians: Float.pi,
        visualRollCorrectionRadians: 0,

        autoAlignVisualBottomToGround: true,

        clipTransitionDuration: 0.0,
        loopedAnimationRepeatDuration: 60.0 * 60.0,

        animationCompletionTolerance: 0.015,
        logClipDurations: true
    )

    var visualCorrectionOrientation: simd_quatf {
        let pitch = simd_quatf(
            angle: visualPitchCorrectionRadians,
            axis: SIMD3<Float>(1, 0, 0)
        )

        let yaw = simd_quatf(
            angle: visualYawCorrectionRadians,
            axis: SIMD3<Float>(0, 1, 0)
        )

        let roll = simd_quatf(
            angle: visualRollCorrectionRadians,
            axis: SIMD3<Float>(0, 0, 1)
        )

        return yaw * pitch * roll
    }
}
