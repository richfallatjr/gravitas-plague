import Foundation
import simd

struct FrameStamp: Sendable, Equatable {
    let frameIndex: UInt64
    let time: TimeInterval
    let deltaTime: Float
}

struct PlayerPoseValue: Sendable, Equatable {
    let positionWorld: SIMD3<Float>
    let forwardWorld: SIMD3<Float>
    let yawRadians: Float
}

struct QuaternionValue: Sendable, Equatable {
    /// Quaternion vector in x, y, z, w order.
    let xyzw: SIMD4<Float>
}

struct TransformValue: Sendable, Equatable {
    let translation: SIMD3<Float>
    let rotation: QuaternionValue
    let scale: SIMD3<Float>

    static let identity = TransformValue(
        translation: .zero,
        rotation: QuaternionValue(
            xyzw: SIMD4<Float>(0, 0, 0, 1)
        ),
        scale: SIMD3<Float>(repeating: 1)
    )
}

struct RevisionToken: Sendable, Equatable, Hashable {
    let value: UInt64
}
