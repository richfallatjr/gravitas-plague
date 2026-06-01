import Foundation
import RealityKit
import simd

@MainActor
final class JockRuntimeDriver {
    enum DriverState: Equatable {
        case stopped
        case playing
        case transitioningToClip
        case transitioningToBase
    }

    private weak var modelEntity: ModelEntity?

    private let adapter: JockSkeletonAdapter
    private let clip: JockAnimClip

    private let baseJointTransforms: [Transform]
    private let jointNames: [String]

    private var playbackTime: TimeInterval = 0
    private var state: DriverState = .stopped

    private var loopEnabled = true

    private var transitionElapsed: TimeInterval = 0
    private var transitionDuration: TimeInterval
    private var transitionFromPose: [Transform] = []
    private var transitionToPose: [Transform] = []
    private var pendingPlayAfterTransition = false

    init(
        modelEntity: ModelEntity,
        adapter: JockSkeletonAdapter,
        clip: JockAnimClip
    ) {
        self.modelEntity = modelEntity
        self.adapter = adapter
        self.clip = clip
        self.baseJointTransforms = modelEntity.jointTransforms
        self.jointNames = modelEntity.jointNames
        self.transitionDuration = clip.transition.transitionDurationSeconds
    }

    func setLoopEnabled(_ enabled: Bool) {
        loopEnabled = enabled
    }

    func playDummyWithTransition() {
        guard let modelEntity else { return }

        playbackTime = 0
        pendingPlayAfterTransition = true
        state = .transitioningToClip

        transitionElapsed = 0
        transitionFromPose = modelEntity.jointTransforms
        transitionToPose = sampleClipPose(at: 0)
    }

    func stop() {
        state = .stopped
        pendingPlayAfterTransition = false
    }

    func resetPoseWithTransition() {
        guard let modelEntity else { return }

        pendingPlayAfterTransition = false
        state = .transitioningToBase

        transitionElapsed = 0
        transitionFromPose = modelEntity.jointTransforms
        transitionToPose = baseJointTransforms
    }

    func resetPoseImmediate() {
        modelEntity?.jointTransforms = baseJointTransforms
        playbackTime = 0
        state = .stopped
        pendingPlayAfterTransition = false
    }

    func update(deltaTime: TimeInterval) {
        guard let modelEntity else { return }

        let clampedDelta = max(0, min(deltaTime, 0.1))

        switch state {
        case .stopped:
            return

        case .transitioningToClip, .transitioningToBase:
            transitionElapsed += clampedDelta

            let alpha = transitionDuration > 0
                ? Float(min(transitionElapsed / transitionDuration, 1.0))
                : 1.0

            let blendedPose = JockPoseMath.blendTransforms(
                from: transitionFromPose,
                to: transitionToPose,
                alpha: alpha
            )

            modelEntity.jointTransforms = blendedPose

            if alpha >= 1.0 {
                if pendingPlayAfterTransition {
                    pendingPlayAfterTransition = false
                    playbackTime = 0
                    state = .playing
                } else {
                    state = .stopped
                }
            }

        case .playing:
            playbackTime += clampedDelta

            let duration = max(clip.timing.durationSeconds, 0.001)

            if loopEnabled {
                playbackTime = playbackTime.truncatingRemainder(dividingBy: duration)
            } else if playbackTime > duration {
                playbackTime = duration
                state = .stopped
            }

            modelEntity.jointTransforms = sampleClipPose(at: playbackTime)
        }
    }

    private func sampleClipPose(at time: TimeInterval) -> [Transform] {
        var output = baseJointTransforms

        for track in clip.tracks {
            guard let runtimeIndex = adapter.runtimeIndex(for: track.joint) else {
                continue
            }

            guard output.indices.contains(runtimeIndex) else {
                continue
            }

            var transform = output[runtimeIndex]

            switch track.channel {
            case "translation_xyz_additive":
                let offset = JockPoseMath.sampleVector3(
                    keys: track.keys,
                    time: time
                )

                if clip.isAdditiveLocal {
                    transform.translation = baseJointTransforms[runtimeIndex].translation + offset
                } else {
                    transform.translation = offset
                }

            case "rotation_quat_wxyz_additive":
                let delta = JockPoseMath.sampleQuaternionWXYZ(
                    keys: track.keys,
                    time: time
                )

                if clip.isAdditiveLocal {
                    transform.rotation = baseJointTransforms[runtimeIndex].rotation * delta
                } else {
                    transform.rotation = delta
                }

            case "rotation_euler_xyz_degrees_additive":
                let delta = JockPoseMath.sampleEulerXYZDegreesAsQuaternion(
                    keys: track.keys,
                    time: time
                )

                if clip.isAdditiveLocal {
                    transform.rotation = baseJointTransforms[runtimeIndex].rotation * delta
                } else {
                    transform.rotation = delta
                }

            case "translation_xyz_absolute":
                transform.translation = JockPoseMath.sampleVector3(
                    keys: track.keys,
                    time: time
                )

            case "rotation_quat_wxyz_absolute":
                transform.rotation = JockPoseMath.sampleQuaternionWXYZ(
                    keys: track.keys,
                    time: time
                )

            default:
                continue
            }

            output[runtimeIndex] = transform
        }

        return output
    }
}
