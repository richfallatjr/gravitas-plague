import Foundation
import simd

struct PhaseOneConfiguration: Equatable {
    let farDistance: Float
    let nearDistance: Float
    let characterHeightOffset: Float

    let idleFarDuration: TimeInterval
    let idleNearDuration: TimeInterval
    let turnRightDuration: TimeInterval

    let walkSpeedMetersPerSecond: Float
    let walkStopEpsilon: Float

    let rootScale: SIMD3<Float>
    let assetYawOffsetRadians: Float

    let clipTransitionDuration: TimeInterval
    let loopedAnimationRepeatDuration: TimeInterval

    static let phaseOneDefault = PhaseOneConfiguration(
        farDistance: 3.05,
        nearDistance: 1.55,
        characterHeightOffset: -1.45,

        idleFarDuration: 2.0,
        idleNearDuration: 2.0,
        turnRightDuration: 1.2,

        walkSpeedMetersPerSecond: 0.40,
        walkStopEpsilon: 0.025,

        rootScale: SIMD3<Float>(1, 1, 1),
        assetYawOffsetRadians: 0,

        clipTransitionDuration: 0.08,
        loopedAnimationRepeatDuration: 60.0 * 60.0
    )
}
