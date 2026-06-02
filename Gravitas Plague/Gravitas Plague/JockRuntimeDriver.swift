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
    private weak var locomotionRootEntity: Entity?

    private let adapter: JockSkeletonAdapter
    private let baseJointTransforms: [Transform]
    private let jointNames: [String]

    private var activeClip: JockAnimClip?
    private var playbackTime: TimeInterval = 0
    private var state: DriverState = .stopped
    private var loopEnabled = true

    private var transitionElapsed: TimeInterval = 0
    private var transitionDuration: TimeInterval = 5.0 / 24.0
    private var transitionFromPose: [Transform] = []
    private var transitionToPose: [Transform] = []
    private var pendingPlayAfterTransition = false

    private var previousLocomotionSample = LocomotionSample.zero

    private struct LocomotionSample: Equatable {
        var forward: Float
        var side: Float
        var vertical: Float
        var yawDegrees: Float

        static let zero = LocomotionSample(
            forward: 0,
            side: 0,
            vertical: 0,
            yawDegrees: 0
        )
    }

    init(
        modelEntity: ModelEntity,
        adapter: JockSkeletonAdapter,
        locomotionRootEntity: Entity? = nil
    ) {
        self.modelEntity = modelEntity
        self.adapter = adapter
        self.locomotionRootEntity = locomotionRootEntity
        self.baseJointTransforms = modelEntity.jointTransforms
        self.jointNames = modelEntity.jointNames
    }

    func setLoopEnabled(_ enabled: Bool) {
        loopEnabled = enabled
    }

    func playClip(_ clip: JockAnimClip, loop: Bool) {
        guard let modelEntity else { return }

        activeClip = clip
        loopEnabled = loop
        playbackTime = 0
        previousLocomotionSample = sampleLocomotion(clip, at: 0)

        transitionDuration = clip.transition.transitionDurationSeconds
        pendingPlayAfterTransition = true
        state = .transitioningToClip

        transitionElapsed = 0
        transitionFromPose = modelEntity.jointTransforms
        transitionToPose = sampleClipPose(clip, at: 0)
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
            guard let activeClip else {
                state = .stopped
                return
            }

            let previousTime = playbackTime
            playbackTime += clampedDelta

            let duration = max(activeClip.timing.durationSeconds, 0.001)
            var didWrap = false

            if loopEnabled {
                if playbackTime >= duration {
                    playbackTime = playbackTime.truncatingRemainder(dividingBy: duration)
                    didWrap = playbackTime < previousTime
                }
            } else if playbackTime > duration {
                playbackTime = duration
                state = .stopped
            }

            modelEntity.jointTransforms = sampleClipPose(activeClip, at: playbackTime)
            applyLocomotionIfNeeded(activeClip, at: playbackTime, didWrap: didWrap)
        }
    }

    private func sampleLocomotion(
        _ clip: JockAnimClip,
        at time: TimeInterval
    ) -> LocomotionSample {
        guard clip.locomotion.isEnabled else {
            return .zero
        }

        let tracks = clip.locomotion.resolvedTracks

        return LocomotionSample(
            forward: JockPoseMath.sampleScalar(
                keys: tracks.forwardMeters,
                time: time
            ),
            side: JockPoseMath.sampleScalar(
                keys: tracks.sideMeters,
                time: time
            ),
            vertical: JockPoseMath.sampleScalar(
                keys: tracks.verticalMeters,
                time: time
            ),
            yawDegrees: JockPoseMath.sampleScalar(
                keys: tracks.yawDegrees,
                time: time
            )
        )
    }

    private func applyLocomotionIfNeeded(
        _ clip: JockAnimClip,
        at time: TimeInterval,
        didWrap: Bool
    ) {
        guard clip.locomotion.isEnabled else {
            return
        }

        guard let locomotionRootEntity else {
            return
        }

        if didWrap {
            previousLocomotionSample = sampleLocomotion(clip, at: 0)
        }

        let current = sampleLocomotion(clip, at: time)

        let deltaForward = current.forward - previousLocomotionSample.forward
        let deltaSide = current.side - previousLocomotionSample.side
        let deltaVertical = current.vertical - previousLocomotionSample.vertical
        let deltaYawDegrees = current.yawDegrees - previousLocomotionSample.yawDegrees

        previousLocomotionSample = current

        let localDelta = SIMD3<Float>(
            deltaSide,
            deltaVertical,
            -deltaForward
        )

        let worldDelta = locomotionRootEntity.orientation.act(localDelta)
        locomotionRootEntity.position += worldDelta

        if abs(deltaYawDegrees) > 0.0001 {
            let yawRadians = JockPoseMath.radians(deltaYawDegrees)

            let deltaRotation = simd_quatf(
                angle: yawRadians,
                axis: SIMD3<Float>(0, 1, 0)
            )

            locomotionRootEntity.orientation =
                deltaRotation * locomotionRootEntity.orientation
        }
    }

    private func sampleClipPose(_ clip: JockAnimClip, at time: TimeInterval) -> [Transform] {
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

            case "scale_xyz_absolute":
                transform.scale = JockPoseMath.sampleVector3(
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
