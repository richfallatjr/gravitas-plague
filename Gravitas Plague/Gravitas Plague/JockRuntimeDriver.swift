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

    private struct ActiveSubAnimation {
        let id: UUID
        let clip: JockAnimClip
        let affectedRuntimeIndices: [Int]
        let blendInDuration: TimeInterval
        let blendOutDuration: TimeInterval
        let duration: TimeInterval

        var playbackTime: TimeInterval = 0

        var isComplete: Bool {
            playbackTime >= duration + blendOutDuration
        }

        func weight() -> Float {
            guard duration > 0 else {
                return 0
            }

            if blendInDuration > 0,
               playbackTime < blendInDuration {
                return Float(
                    min(max(playbackTime / blendInDuration, 0), 1)
                )
            }

            if playbackTime <= duration {
                return 1
            }

            if blendOutDuration > 0 {
                let outTime = playbackTime - duration
                let alpha = Float(min(max(outTime / blendOutDuration, 0), 1))
                return 1.0 - alpha
            }

            return 0
        }

        func subClipSampleTime() -> TimeInterval {
            min(max(playbackTime, 0), duration)
        }
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
    private var activeSubAnimations: [ActiveSubAnimation] = []
    private var preparedClipsByID: [String: JockPreparedClip] = [:]

    private(set) var currentJointTransforms: [Transform]
    private(set) var currentActiveClipID: String?
    private(set) var currentPlaybackTime: TimeInterval = 0

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
        self.currentJointTransforms = modelEntity.jointTransforms
    }

    func prewarmClips(_ clips: [JockAnimClip]) {
        var prepared: [String: JockPreparedClip] = [:]

        for clip in clips {
            let preparedClip = prepareClip(clip)
            prepared[clip.clipID] = preparedClip
        }

        preparedClipsByID = prepared

        print("[Gravitas Jock] Prewarmed \(preparedClipsByID.count) clips.")
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
        currentActiveClipID = clip.clipID
        currentPlaybackTime = 0

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
            let basePose = sampleClipPose(clip, at: 0)
            let finalPose = applyActiveSubAnimations(
                to: basePose,
                deltaTime: 0
            )
            setJointTransforms(finalPose, on: modelEntity)
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

    func triggerSubAnimation(
        _ clip: JockAnimClip,
        transitionFPS fallbackFPS: Double = 24.0
    ) {
        guard clip.isSubAnimationOverride else {
            print("[Gravitas SubAnim] Ignored non-sub-animation clip: \(clip.clipID)")
            return
        }

        let preparedClip: JockPreparedClip

        if let cached = preparedClipsByID[clip.clipID] {
            preparedClip = cached
        } else {
            print("[Gravitas SubAnim] WARNING: triggering unprepared sub-animation \(clip.clipID). Prewarming missed it.")
            let prepared = prepareClip(clip)
            preparedClipsByID[clip.clipID] = prepared
            preparedClip = prepared
        }

        guard let preparedSubAnimation = preparedClip.subAnimation else {
            print("[Gravitas SubAnim] Prepared clip has no sub-animation metadata: \(clip.clipID)")
            return
        }

        guard !preparedSubAnimation.affectedRuntimeIndices.isEmpty else {
            print(
                """
                [Gravitas SubAnim] No affected joints mapped
                  clipID: \(clip.clipID)
                  affectedJoints: \(preparedSubAnimation.affectedJoints.joined(separator: ", "))
                """
            )
            return
        }

        activeSubAnimations.removeAll { existing in
            existing.clip.clipID == clip.clipID
        }

        let instance = ActiveSubAnimation(
            id: UUID(),
            clip: clip,
            affectedRuntimeIndices: preparedSubAnimation.affectedRuntimeIndices,
            blendInDuration: preparedSubAnimation.blendInDuration,
            blendOutDuration: preparedSubAnimation.blendOutDuration,
            duration: preparedClip.duration,
            playbackTime: 0
        )

        activeSubAnimations.append(instance)

        print(
            """
            [Gravitas SubAnim] Triggered prepared sub-animation
              clipID: \(clip.clipID)
              affectedJoints: \(preparedSubAnimation.affectedJoints.joined(separator: ", "))
              mappedIndices: \(preparedSubAnimation.affectedRuntimeIndices.count)
              blendInDuration: \(String(format: "%.3f", preparedSubAnimation.blendInDuration))
              blendOutDuration: \(String(format: "%.3f", preparedSubAnimation.blendOutDuration))
              baseAnimationContinues: \(clip.resolvedBaseAnimationContinues)
              duration: \(String(format: "%.3f", preparedClip.duration))
            """
        )
    }

    func stop() {
        state = .stopped
        activeClip = nil
        currentActiveClipID = nil
        currentPlaybackTime = 0
        currentJointTransforms = modelEntity?.jointTransforms ?? baseJointTransforms
        activeRuntimeOverride = .identity
        activeSubAnimations.removeAll()
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
        currentActiveClipID = nil
        currentPlaybackTime = 0
        activeRuntimeOverride = .identity
        activeSubAnimations.removeAll()
        resetFrozenLocomotionState()
    }

    func resetPoseImmediate(
        visualOffset: simd_quatf = simd_quatf(
            angle: 0,
            axis: SIMD3<Float>(0, 1, 0)
        )
    ) {
        if let modelEntity {
            setJointTransforms(baseJointTransforms, on: modelEntity)
        } else {
            currentJointTransforms = baseJointTransforms
        }
        visualOffsetEntity?.orientation = visualOffset
        playbackTime = 0
        state = .stopped
        activeClip = nil
        currentActiveClipID = nil
        currentPlaybackTime = 0
        activeRuntimeOverride = .identity
        activeSubAnimations.removeAll()
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

            let finalPose = applyActiveSubAnimations(
                to: blendedPose,
                deltaTime: clampedDelta
            )
            setJointTransforms(finalPose, on: modelEntity)

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
                currentPlaybackTime = 0
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

            let finalPose = applyActiveSubAnimations(
                to: blendedPose,
                deltaTime: clampedDelta
            )
            setJointTransforms(finalPose, on: modelEntity)

            let visualOffset = simd_slerp(
                transitionFromVisualOffset,
                transitionToVisualOffset,
                alpha
            )

            visualOffsetEntity?.orientation = visualOffset

            if alpha >= 1.0 {
                state = .stopped
                activeClip = nil
                currentActiveClipID = nil
                currentPlaybackTime = 0
                activeRuntimeOverride = .identity
                resetFrozenLocomotionState()
            }

        case .playing:
            guard let activeClip else {
                state = .stopped
                currentActiveClipID = nil
                currentPlaybackTime = 0
                return
            }

            let previousTime = playbackTime
            playbackTime += clampedDelta
            currentPlaybackTime = playbackTime

            let duration = max(activeClip.timing.durationSeconds, 0.001)

            if loopCurrentClip {
                var didWrap = false

                if playbackTime >= duration {
                    playbackTime = playbackTime.truncatingRemainder(dividingBy: duration)
                    currentPlaybackTime = playbackTime
                    didWrap = playbackTime < previousTime
                }

                let basePose = sampleClipPose(activeClip, at: playbackTime)
                let finalPose = applyActiveSubAnimations(
                    to: basePose,
                    deltaTime: clampedDelta
                )
                setJointTransforms(finalPose, on: modelEntity)
                applyLocomotionFromFrozenOrigin(activeClip, at: playbackTime, didWrap: didWrap)

            } else {
                if playbackTime >= duration {
                    playbackTime = duration
                    currentPlaybackTime = playbackTime

                    let basePose = sampleClipPose(activeClip, at: playbackTime)
                    let finalPose = applyActiveSubAnimations(
                        to: basePose,
                        deltaTime: clampedDelta
                    )
                    setJointTransforms(finalPose, on: modelEntity)
                    applyLocomotionFromFrozenOrigin(activeClip, at: playbackTime, didWrap: false)

                    commitRuntimeOverrideAtClipCompletion()

                    state = .stopped
                    let completedClip = activeClip
                    self.activeClip = nil
                    currentActiveClipID = nil
                    currentPlaybackTime = 0

                    onClipCompleted?(completedClip)
                    return
                }

                let basePose = sampleClipPose(activeClip, at: playbackTime)
                let finalPose = applyActiveSubAnimations(
                    to: basePose,
                    deltaTime: clampedDelta
                )
                setJointTransforms(finalPose, on: modelEntity)
                applyLocomotionFromFrozenOrigin(activeClip, at: playbackTime, didWrap: false)
            }
        }
    }

    private func setJointTransforms(
        _ transforms: [Transform],
        on modelEntity: ModelEntity
    ) {
        modelEntity.jointTransforms = transforms
        currentJointTransforms = transforms
    }

    private func sampleClipPose(
        _ clip: JockAnimClip,
        at time: TimeInterval
    ) -> [Transform] {
        if let preparedClip = preparedClipsByID[clip.clipID] {
            return samplePreparedClipPose(
                preparedClip,
                at: time
            )
        }

        print("[Gravitas Jock] WARNING: sampling unprepared clip \(clip.clipID). This can hitch.")

        let preparedClip = prepareClip(clip)
        preparedClipsByID[clip.clipID] = preparedClip

        return samplePreparedClipPose(
            preparedClip,
            at: time
        )
    }

    private func prepareClip(_ clip: JockAnimClip) -> JockPreparedClip {
        let preparedTracks: [JockPreparedTrack] = clip.tracks.compactMap { track in
            guard let runtimeIndex = adapter.runtimeIndex(for: track.joint) else {
                return nil
            }

            let sortedKeys = track.keys.sorted { $0.t < $1.t }

            return JockPreparedTrack(
                joint: track.joint,
                runtimeIndex: runtimeIndex,
                channel: track.channel,
                keys: sortedKeys
            )
        }

        let preparedSubAnimation: JockPreparedSubAnimation?

        if clip.isSubAnimationOverride {
            let affectedJoints = clip.resolvedAffectedJoints

            var seenRuntimeIndices = Set<Int>()
            let affectedRuntimeIndices = affectedJoints.compactMap { jointName in
                adapter.runtimeIndex(for: jointName)
            }.filter { runtimeIndex in
                seenRuntimeIndices.insert(runtimeIndex).inserted
            }

            let fps = clip.timing.fps > 0
                ? clip.timing.fps
                : 24.0

            preparedSubAnimation = JockPreparedSubAnimation(
                affectedJoints: affectedJoints,
                affectedRuntimeIndices: affectedRuntimeIndices,
                blendInDuration: Double(clip.resolvedBlendInFrames) / fps,
                blendOutDuration: Double(clip.resolvedBlendOutFrames) / fps
            )
        } else {
            preparedSubAnimation = nil
        }

        let firstPose = sampleClipPoseUncached(
            clip,
            preparedTracks: preparedTracks,
            at: 0
        )

        let lastPose = sampleClipPoseUncached(
            clip,
            preparedTracks: preparedTracks,
            at: max(clip.timing.durationSeconds, 0.001)
        )

        return JockPreparedClip(
            clip: clip,
            tracks: preparedTracks,
            subAnimation: preparedSubAnimation,
            firstPose: firstPose,
            lastPose: lastPose
        )
    }

    private func samplePreparedClipPose(
        _ preparedClip: JockPreparedClip,
        at time: TimeInterval
    ) -> [Transform] {
        if time <= 0 {
            return preparedClip.firstPose
        }

        if time >= preparedClip.duration {
            return preparedClip.lastPose
        }

        return sampleClipPoseUncached(
            preparedClip.clip,
            preparedTracks: preparedClip.tracks,
            at: time
        )
    }

    private func sampleClipPoseUncached(
        _ clip: JockAnimClip,
        preparedTracks: [JockPreparedTrack],
        at time: TimeInterval
    ) -> [Transform] {
        var output = baseJointTransforms

        for track in preparedTracks {
            guard output.indices.contains(track.runtimeIndex) else {
                continue
            }

            var transform = output[track.runtimeIndex]

            switch track.channel {
            case "translation_xyz_additive":
                let offset = JockPoseMath.sampleVector3Sorted(keys: track.keys, time: time)

                if clip.isAdditiveLocal {
                    transform.translation = baseJointTransforms[track.runtimeIndex].translation + offset
                } else {
                    transform.translation = offset
                }

            case "rotation_quat_wxyz_additive":
                let delta = JockPoseMath.sampleQuaternionWXYZSorted(keys: track.keys, time: time)

                if clip.isAdditiveLocal {
                    transform.rotation = baseJointTransforms[track.runtimeIndex].rotation * delta
                } else {
                    transform.rotation = delta
                }

            case "rotation_euler_xyz_degrees_additive":
                let delta = JockPoseMath.sampleEulerXYZDegreesAsQuaternionSorted(keys: track.keys, time: time)

                if clip.isAdditiveLocal {
                    transform.rotation = baseJointTransforms[track.runtimeIndex].rotation * delta
                } else {
                    transform.rotation = delta
                }

            case "translation_xyz_absolute":
                transform.translation = JockPoseMath.sampleVector3Sorted(keys: track.keys, time: time)

            case "rotation_quat_wxyz_absolute":
                transform.rotation = JockPoseMath.sampleQuaternionWXYZSorted(keys: track.keys, time: time)

            case "scale_xyz_absolute":
                transform.scale = JockPoseMath.sampleVector3Sorted(keys: track.keys, time: time)

            default:
                continue
            }

            output[track.runtimeIndex] = transform
        }

        return output
    }

    private func applyActiveSubAnimations(
        to basePose: [Transform],
        deltaTime: TimeInterval
    ) -> [Transform] {
        guard !activeSubAnimations.isEmpty else {
            return basePose
        }

        var output = basePose
        var updatedSubAnimations: [ActiveSubAnimation] = []

        for var subAnimation in activeSubAnimations {
            subAnimation.playbackTime += deltaTime

            if subAnimation.isComplete {
                continue
            }

            let weight = subAnimation.weight()

            guard weight > 0.0001 else {
                updatedSubAnimations.append(subAnimation)
                continue
            }

            let subPose = sampleClipPose(
                subAnimation.clip,
                at: subAnimation.subClipSampleTime()
            )

            for runtimeIndex in subAnimation.affectedRuntimeIndices {
                guard output.indices.contains(runtimeIndex),
                      subPose.indices.contains(runtimeIndex) else {
                    continue
                }

                output[runtimeIndex].translation = JockPoseMath.lerp(
                    output[runtimeIndex].translation,
                    subPose[runtimeIndex].translation,
                    weight
                )

                output[runtimeIndex].scale = JockPoseMath.lerp(
                    output[runtimeIndex].scale,
                    subPose[runtimeIndex].scale,
                    weight
                )

                output[runtimeIndex].rotation = JockPoseMath.slerp(
                    output[runtimeIndex].rotation,
                    subPose[runtimeIndex].rotation,
                    weight
                )
            }

            updatedSubAnimations.append(subAnimation)
        }

        activeSubAnimations = updatedSubAnimations

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
