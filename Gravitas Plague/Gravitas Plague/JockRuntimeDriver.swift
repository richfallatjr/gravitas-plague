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

    private weak var modelEntity: ModelEntity?
    private weak var locomotionRootEntity: Entity?
    private weak var visualOffsetEntity: Entity?

    private let adapter: JockSkeletonAdapter
    private let baseJointTransforms: [Transform]
    private let jointNames: [String]

    private var activeClip: JockAnimClip?
    private var playbackTime: TimeInterval = 0
    private var state: DriverState = .stopped

    private var loopCurrentClip = false

    private var transitionElapsed: TimeInterval = 0
    private var transitionDuration: TimeInterval = 5.0 / 24.0
    private var transitionFromPose: [Transform] = []
    private var transitionToPose: [Transform] = []
    private var transitionFromVisualOffset = simd_quatf(
        angle: 0,
        axis: SIMD3<Float>(0, 1, 0)
    )
    private var transitionToVisualOffset = simd_quatf(
        angle: 0,
        axis: SIMD3<Float>(0, 1, 0)
    )

    private var frozenClipRootPosition = SIMD3<Float>(0, 0, 0)
    private var frozenClipRootOrientation = simd_quatf(
        angle: 0,
        axis: SIMD3<Float>(0, 1, 0)
    )
    private var clipLocomotionZero = LocomotionSample.zero
    private var locomotionLoopCarryPosition = SIMD3<Float>(0, 0, 0)
    private var locomotionLoopCarryOrientation = simd_quatf(
        angle: 0,
        axis: SIMD3<Float>(0, 1, 0)
    )
    private var previousRelativeLocomotionSample = LocomotionSample.zero
    private var activeRuntimeOverride = JockRuntimeClipOverride.identity

    var onClipCompleted: ((JockAnimClip) -> Void)?
    var locomotionDeltaHandler: ((JockRuntimeLocomotionDelta) -> Bool)?

    init(
        modelEntity: ModelEntity,
        adapter: JockSkeletonAdapter,
        locomotionRootEntity: Entity? = nil,
        visualOffsetEntity: Entity? = nil
    ) {
        self.modelEntity = modelEntity
        self.adapter = adapter
        self.locomotionRootEntity = locomotionRootEntity
        self.visualOffsetEntity = visualOffsetEntity
        self.baseJointTransforms = modelEntity.jointTransforms
        self.jointNames = modelEntity.jointNames
    }

    func playClip(
        _ clip: JockAnimClip,
        loop: Bool,
        transition: Bool = true,
        runtimeOverride: JockRuntimeClipOverride = .identity
    ) {
        guard let modelEntity else { return }

        activeClip = clip
        activeRuntimeOverride = runtimeOverride
        loopCurrentClip = loop
        playbackTime = 0

        captureRootOriginForNewClip(clip)

        transitionDuration = clip.transition.transitionDurationSeconds
        let targetVisualOffset = runtimeOverride.entryVisualOffsetOrientation

        if transition {
            state = .transitioningToClip
            transitionElapsed = 0

            // Transition from the current visible skeleton pose.
            transitionFromPose = modelEntity.jointTransforms
            transitionToPose = sampleClipPose(clip, at: 0)
            transitionFromVisualOffset =
                visualOffsetEntity?.orientation ??
                simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            transitionToVisualOffset = targetVisualOffset
        } else {
            state = .playing
            visualOffsetEntity?.orientation = targetVisualOffset
            modelEntity.jointTransforms = sampleClipPose(clip, at: 0)
            applyLocomotionFromFrozenOrigin(clip, at: 0, didWrap: false)
        }

        print(
            """
            [Gravitas Virtual Root] Starting clip
              clipID: \(clip.clipID)
              entryHeading: \(runtimeOverride.entryHeadingDegrees)
              exitHeading: \(runtimeOverride.exitHeadingDegrees)
              commitRootYaw: \(runtimeOverride.commitRootYawOnCompletion)
            """
        )
    }

    func stop() {
        state = .stopped
        activeClip = nil
        activeRuntimeOverride = .identity
        resetFrozenLocomotionState()
    }

    func resetPoseWithTransition(
        visualOffset: simd_quatf = simd_quatf(
            angle: 0,
            axis: SIMD3<Float>(0, 1, 0)
        )
    ) {
        guard let modelEntity else { return }

        state = .transitioningToBase
        transitionElapsed = 0
        transitionFromPose = modelEntity.jointTransforms
        transitionToPose = baseJointTransforms
        transitionFromVisualOffset =
            visualOffsetEntity?.orientation ??
            simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        transitionToVisualOffset = visualOffset
        activeClip = nil
        activeRuntimeOverride = .identity
        resetFrozenLocomotionState()
    }

    func resetPoseImmediate(
        visualOffset: simd_quatf = simd_quatf(
            angle: 0,
            axis: SIMD3<Float>(0, 1, 0)
        )
    ) {
        modelEntity?.jointTransforms = baseJointTransforms
        visualOffsetEntity?.orientation = visualOffset
        playbackTime = 0
        state = .stopped
        activeClip = nil
        activeRuntimeOverride = .identity
        resetFrozenLocomotionState()
    }

    func update(deltaTime: TimeInterval) {
        guard let modelEntity else { return }

        let clampedDelta = max(0, min(deltaTime, 0.1))

        switch state {
        case .stopped:
            return

        case .transitioningToClip:
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

            let visualOffset = simd_slerp(
                transitionFromVisualOffset,
                transitionToVisualOffset,
                alpha
            )

            visualOffsetEntity?.orientation = visualOffset

            if let activeClip,
               activeClip.locomotion.isEnabled,
               shouldApplyLocomotionDuringTransition(activeClip) {
                let transitionClipTime = min(
                    transitionElapsed,
                    activeClip.timing.durationSeconds
                )

                applyLocomotionFromFrozenOrigin(
                    activeClip,
                    at: transitionClipTime,
                    didWrap: false
                )
            } else {
                locomotionRootEntity?.position = frozenClipRootPosition
                locomotionRootEntity?.orientation = frozenClipRootOrientation
            }

            if alpha >= 1.0 {
                playbackTime = 0
                state = .playing
            }

        case .transitioningToBase:
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

            let visualOffset = simd_slerp(
                transitionFromVisualOffset,
                transitionToVisualOffset,
                alpha
            )

            visualOffsetEntity?.orientation = visualOffset

            if alpha >= 1.0 {
                state = .stopped
                activeClip = nil
                activeRuntimeOverride = .identity
                resetFrozenLocomotionState()
            }

        case .playing:
            guard let activeClip else {
                state = .stopped
                return
            }

            let previousTime = playbackTime
            playbackTime += clampedDelta

            let duration = max(activeClip.timing.durationSeconds, 0.001)

            if loopCurrentClip {
                var didWrap = false

                if playbackTime >= duration {
                    playbackTime = playbackTime.truncatingRemainder(dividingBy: duration)
                    didWrap = playbackTime < previousTime
                }

                modelEntity.jointTransforms = sampleClipPose(activeClip, at: playbackTime)
                applyLocomotionFromFrozenOrigin(activeClip, at: playbackTime, didWrap: didWrap)

            } else {
                if playbackTime >= duration {
                    playbackTime = duration

                    modelEntity.jointTransforms = sampleClipPose(activeClip, at: playbackTime)
                    applyLocomotionFromFrozenOrigin(activeClip, at: playbackTime, didWrap: false)

                    commitRuntimeOverrideAtClipCompletion()

                    state = .stopped
                    let completedClip = activeClip
                    self.activeClip = nil

                    onClipCompleted?(completedClip)
                    return
                }

                modelEntity.jointTransforms = sampleClipPose(activeClip, at: playbackTime)
                applyLocomotionFromFrozenOrigin(activeClip, at: playbackTime, didWrap: false)
            }
        }
    }

    private func sampleClipPose(
        _ clip: JockAnimClip,
        at time: TimeInterval
    ) -> [Transform] {
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
                let offset = JockPoseMath.sampleVector3(keys: track.keys, time: time)

                if clip.isAdditiveLocal {
                    transform.translation = baseJointTransforms[runtimeIndex].translation + offset
                } else {
                    transform.translation = offset
                }

            case "rotation_quat_wxyz_additive":
                let delta = JockPoseMath.sampleQuaternionWXYZ(keys: track.keys, time: time)

                if clip.isAdditiveLocal {
                    transform.rotation = baseJointTransforms[runtimeIndex].rotation * delta
                } else {
                    transform.rotation = delta
                }

            case "rotation_euler_xyz_degrees_additive":
                let delta = JockPoseMath.sampleEulerXYZDegreesAsQuaternion(keys: track.keys, time: time)

                if clip.isAdditiveLocal {
                    transform.rotation = baseJointTransforms[runtimeIndex].rotation * delta
                } else {
                    transform.rotation = delta
                }

            case "translation_xyz_absolute":
                transform.translation = JockPoseMath.sampleVector3(keys: track.keys, time: time)

            case "rotation_quat_wxyz_absolute":
                transform.rotation = JockPoseMath.sampleQuaternionWXYZ(keys: track.keys, time: time)

            case "scale_xyz_absolute":
                transform.scale = JockPoseMath.sampleVector3(keys: track.keys, time: time)

            default:
                continue
            }

            output[runtimeIndex] = transform
        }

        return output
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

    private func captureRootOriginForNewClip(_ clip: JockAnimClip) {
        guard let root = locomotionRootEntity else {
            resetFrozenLocomotionState()
            return
        }

        frozenClipRootPosition = root.position
        frozenClipRootOrientation = root.orientation

        // Treat whatever the clip says at t=0 as local zero. Carried heading
        // belongs to the root entity, not the next clip's first key.
        clipLocomotionZero = sampleLocomotion(clip, at: 0)

        locomotionLoopCarryPosition = .zero
        locomotionLoopCarryOrientation = simd_quatf(
            angle: 0,
            axis: SIMD3<Float>(0, 1, 0)
        )
        previousRelativeLocomotionSample = .zero

        guard clip.locomotion.isEnabled else {
            return
        }

        let start = clipLocomotionZero

        print(
            """
            [Gravitas Locomotion] New clip root origin captured
              clipID: \(clip.clipID)
              rootPosition: \(root.position)
              startForward: \(start.forward)
              startSide: \(start.side)
              startVertical: \(start.vertical)
              startYawDegrees: \(start.yawDegrees)
              note: start locomotion is normalized to local zero.
            """
        )

        if abs(start.forward) > 0.0001 ||
            abs(start.side) > 0.0001 ||
            abs(start.vertical) > 0.0001 ||
            abs(start.yawDegrees) > 0.0001 {
            print(
                """
                [Gravitas Locomotion] Normalizing non-zero clip start locomotion
                  clipID: \(clip.clipID)
                  startForward: \(start.forward)
                  startSide: \(start.side)
                  startVertical: \(start.vertical)
                  startYawDegrees: \(start.yawDegrees)
                  note: clip start is treated as local zero.
                """
            )
        }
    }

    private func shouldApplyLocomotionDuringTransition(_ clip: JockAnimClip) -> Bool {
        let mode = clip.locomotion.locomotionStartMode ?? "after_transition"

        return mode == "during_transition" || mode == "immediate"
    }

    private func applyLocomotionFromFrozenOrigin(
        _ clip: JockAnimClip,
        at time: TimeInterval,
        didWrap: Bool
    ) {
        if tryEmitLocomotionDeltaToHandler(
            clip,
            at: time,
            didWrap: didWrap
        ) {
            return
        }

        guard clip.locomotion.isEnabled else {
            return
        }

        guard let root = locomotionRootEntity else {
            return
        }

        if didWrap {
            let endSample = sampleLocomotion(
                clip,
                at: max(clip.timing.durationSeconds, 0.001)
            )

            let endRelative = relativeLocomotionSample(endSample)

            let endLocalDelta = SIMD3<Float>(
                endRelative.side,
                endRelative.vertical,
                -endRelative.forward
            )

            let endYaw = simd_quatf(
                angle: JockPoseMath.radians(endRelative.yawDegrees),
                axis: SIMD3<Float>(0, 1, 0)
            )

            locomotionLoopCarryPosition +=
                locomotionLoopCarryOrientation.act(endLocalDelta)

            locomotionLoopCarryOrientation =
                endYaw * locomotionLoopCarryOrientation
        }

        let current = sampleLocomotion(clip, at: time)
        let relative = relativeLocomotionSample(current)

        let localDelta = SIMD3<Float>(
            relative.side,
            relative.vertical,
            -relative.forward
        )

        let carriedOriginPosition =
            frozenClipRootPosition +
            frozenClipRootOrientation.act(locomotionLoopCarryPosition)

        let carriedOriginOrientation =
            locomotionLoopCarryOrientation * frozenClipRootOrientation

        let localYaw = simd_quatf(
            angle: JockPoseMath.radians(relative.yawDegrees),
            axis: SIMD3<Float>(0, 1, 0)
        )

        root.position =
            carriedOriginPosition +
            carriedOriginOrientation.act(localDelta)

        root.orientation =
            localYaw * carriedOriginOrientation
    }

    private func relativeLocomotionSample(
        _ sample: LocomotionSample
    ) -> LocomotionSample {
        LocomotionSample(
            forward: sample.forward - clipLocomotionZero.forward,
            side: sample.side - clipLocomotionZero.side,
            vertical: sample.vertical - clipLocomotionZero.vertical,
            yawDegrees: sample.yawDegrees - clipLocomotionZero.yawDegrees
        )
    }

    private func tryEmitLocomotionDeltaToHandler(
        _ clip: JockAnimClip,
        at time: TimeInterval,
        didWrap: Bool
    ) -> Bool {
        guard clip.locomotion.isEnabled else {
            return false
        }

        guard let locomotionDeltaHandler else {
            return false
        }

        var wasConsumed = false

        func emitDelta(
            from previous: LocomotionSample,
            to current: LocomotionSample,
            time: TimeInterval,
            didWrap: Bool
        ) {
            let delta = JockRuntimeLocomotionDelta(
                clipID: clip.clipID,
                time: time,
                didWrap: didWrap,
                forwardMeters: current.forward - previous.forward,
                sideMeters: current.side - previous.side,
                verticalMeters: current.vertical - previous.vertical,
                yawDegrees: current.yawDegrees - previous.yawDegrees
            )

            wasConsumed = locomotionDeltaHandler(delta) || wasConsumed
        }

        if didWrap {
            let endTime = max(clip.timing.durationSeconds, 0.001)
            let endSample = relativeLocomotionSample(
                sampleLocomotion(clip, at: endTime)
            )

            emitDelta(
                from: previousRelativeLocomotionSample,
                to: endSample,
                time: endTime,
                didWrap: true
            )

            previousRelativeLocomotionSample = .zero
        }

        let currentSample = relativeLocomotionSample(
            sampleLocomotion(clip, at: time)
        )

        emitDelta(
            from: previousRelativeLocomotionSample,
            to: currentSample,
            time: time,
            didWrap: didWrap
        )

        previousRelativeLocomotionSample = currentSample

        return wasConsumed
    }

    private func commitRuntimeOverrideAtClipCompletion() {
        guard activeRuntimeOverride.commitRootYawOnCompletion else {
            return
        }

        guard let root = locomotionRootEntity else {
            return
        }

        let delta = activeRuntimeOverride.rootYawDeltaOrientation

        // Same conceptual layer as locomotion yaw: the root owns accumulated heading.
        root.orientation = delta * root.orientation

        visualOffsetEntity?.orientation =
            activeRuntimeOverride.exitVisualOffsetOrientation

        print(
            """
            [Gravitas Virtual Root] Clip completion committed root yaw
              entryHeading: \(activeRuntimeOverride.entryHeadingDegrees)
              exitHeading: \(activeRuntimeOverride.exitHeadingDegrees)
              yawDelta: \(activeRuntimeOverride.yawDeltaDegrees)
            """
        )
    }

    private func resetFrozenLocomotionState() {
        frozenClipRootPosition = .zero
        frozenClipRootOrientation = simd_quatf(
            angle: 0,
            axis: SIMD3<Float>(0, 1, 0)
        )
        clipLocomotionZero = .zero
        locomotionLoopCarryPosition = .zero
        locomotionLoopCarryOrientation = simd_quatf(
            angle: 0,
            axis: SIMD3<Float>(0, 1, 0)
        )
        previousRelativeLocomotionSample = .zero
    }
}
