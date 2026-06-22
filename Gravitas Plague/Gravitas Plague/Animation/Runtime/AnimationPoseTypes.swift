import Foundation
import simd

struct AnimationPlaybackValue: Sendable {
    let activeClipID: String?
    let activeClipTime: Float
    let previousClipTime: Float
    let playbackRate: Float
    let isLooping: Bool
}

struct AnimationTransitionValue: Sendable {
    let sourceClipID: String
    let destinationClipID: String
    let sourceTime: Float
    let destinationTime: Float
    let blendAlpha: Float
}

struct SubAnimationValue: Sendable {
    let instanceID: UUID
    let clipID: String
    let localTime: Float
    let affectedJointIndices: [Int]
    let blendWeight: Float
}

struct RuntimeOverrideValue: Sendable {
    let entryYawDegrees: Float
    let exitYawDegrees: Float
    let commitYaw: Bool
}

struct AnimationPoseRequest: Sendable {
    let enemyID: UUID
    let revision: RevisionToken
    let frame: FrameStamp

    let rigID: String
    let playback: AnimationPlaybackValue
    let transition: AnimationTransitionValue?
    let subAnimations: [SubAnimationValue]

    let locomotionPolicyRawValue: String
    let posePolicyRawValue: String
    let runtimeOverride: RuntimeOverrideValue?
}

struct AnimationPoseCommand: Sendable {
    let enemyID: UUID
    let revision: RevisionToken
    let frameIndex: UInt64

    let jointTransforms: [TransformValue]
    let visualOffset: TransformValue
    let rootMotionDelta: SIMD3<Float>
    let rootYawDeltaRadians: Float

    let completedClipID: String?
    let shouldCommitRuntimeOverride: Bool
}

struct AnimationPoseBatchRequest: Sendable {
    let frame: FrameStamp
    let requests: [AnimationPoseRequest]
}

struct AnimationPoseBatchCommand: Sendable {
    let frameIndex: UInt64
    let commands: [AnimationPoseCommand]
}
