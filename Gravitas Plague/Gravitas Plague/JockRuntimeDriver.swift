import Foundation
import RealityKit
import simd

enum JockClipLocomotionPolicy: Equatable {
    case useClipLocomotion
    case ignoreClipLocomotion
}

enum JockPoseApplicationPolicy: String, Codable, Equatable {
    case authorAbsoluteLocal
    case preserveTargetSkeleton
    case preserveTargetSkeletonDirectionRetarget
    case sourceRestDeltaToTargetRest
}

struct JockJointRotationCorrection {
    let pre: simd_quatf
    let post: simd_quatf

    static let identity = JockJointRotationCorrection(
        pre: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
        post: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    )
}

struct JockWorldJointPose {
    let jointName: String
    let worldPosition: SIMD3<Float>
    let worldRotation: simd_quatf
}

struct JockWorldPose {
    let frameTimeSeconds: TimeInterval
    let joints: [String: JockWorldJointPose]
}

struct SourceToTargetBodyBasisMap {
    let valid: Bool
    let rotation: simd_quatf
}

struct SourceRigRestPose {
    let characterID: String
    let skeletonHash: String
    let jointOrder: [String]
    let restLocalTransforms: [String: Transform]
    let resolution: String
}

struct GlobalJointTransform {
    let translation: SIMD3<Float>
    let rotation: simd_quatf
    let scale: SIMD3<Float>
}

@MainActor
final class SourceRigRestPoseCache {
    static let shared = SourceRigRestPoseCache()

    private var cache: [String: SourceRigRestPose] = [:]

    private init() {}

    func resolve(
        clip: JockAnimClip,
        rig: JockRigDefinition,
        defaultDadUSDZURL: URL?
    ) throws -> SourceRigRestPose {
        if let embedded = sourceRestPoseFromEmbeddedClipMetadata(
            clip: clip,
            rig: rig
        ) {
            return embedded
        }

        if let path = clip.source.sourcePath,
           FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            return try loadRestPoseFromUSDZ(
                url: url,
                rig: rig,
                resolution: "sourceUSDZPath"
            )
        }

        if let defaultDadUSDZURL {
            print(
                """
                [JockRuntimeDriver] legacy clip source rig inferred as dad_biped
                  clip: \(clip.clipID)
                  sourceFile: \(clip.source.sourceFile)
                """
            )

            return try loadRestPoseFromUSDZ(
                url: defaultDadUSDZURL,
                rig: rig,
                resolution: "defaultDadUSDZ"
            )
        }

        throw NSError(
            domain: "SourceRigRestPoseCache",
            code: 404,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "No source rig rest pose available for clip \(clip.clipID). Do not retarget using first key as rest."
            ]
        )
    }

    private func sourceRestPoseFromEmbeddedClipMetadata(
        clip: JockAnimClip,
        rig: JockRigDefinition
    ) -> SourceRigRestPose? {
        guard let sourceRig = clip.sourceRig else {
            return nil
        }

        let transforms = sourceRig.restLocalTransforms.reduce(
            into: [String: Transform]()
        ) { partial, pair in
            partial[pair.key] = Self.transform(from: pair.value)
        }

        guard !transforms.isEmpty else {
            return nil
        }

        return SourceRigRestPose(
            characterID: sourceRig.characterID ?? "dad_biped",
            skeletonHash: sourceRig.skeletonHash ?? "embedded-no-hash",
            jointOrder: sourceRig.jointPaths.isEmpty
                ? rig.canonicalLeafNames
                : sourceRig.jointPaths.map { path in
                    path.split(separator: "/").last.map(String.init) ?? path
                },
            restLocalTransforms: transforms,
            resolution: "embeddedClipSourceRig"
        )
    }

    private func loadRestPoseFromUSDZ(
        url: URL,
        rig: JockRigDefinition,
        resolution: String
    ) throws -> SourceRigRestPose {
        let key = "\(resolution)|\(url.path)"

        if let cached = cache[key] {
            return cached
        }

        let root = try Entity.load(contentsOf: url)

        guard let modelEntity = Self.firstSkinnedModelEntity(in: root) else {
            throw NSError(
                domain: "SourceRigRestPoseCache",
                code: 1001,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No skinned ModelEntity with joints found in \(url.lastPathComponent)."
                ]
            )
        }

        let skeletonMap = JockSkeletonMap(
            schema: "com.gravitas.skeleton_map.v0",
            mapID: "SourceRigRestPoseCache.identity",
            sourceRigID: rig.rigID,
            sourceRigVersion: rig.version,
            targetRigID: rig.rigID,
            targetRigVersion: rig.version,
            canonicalToSource: Dictionary(
                uniqueKeysWithValues: rig.canonicalLeafNames.map { ($0, $0) }
            )
        )
        let adapter = JockSkeletonAdapter(
            rig: rig,
            skeletonMap: skeletonMap,
            runtimeJointNames: modelEntity.jointNames
        )
        let restTransforms = rig.canonicalLeafNames.reduce(
            into: [String: Transform]()
        ) { partial, joint in
            guard let index = adapter.runtimeIndex(for: joint),
                  modelEntity.jointTransforms.indices.contains(index) else {
                return
            }

            partial[joint] = modelEntity.jointTransforms[index]
        }

        let pose = SourceRigRestPose(
            characterID: url.deletingPathExtension().lastPathComponent,
            skeletonHash: "runtime-loaded-\(url.lastPathComponent)",
            jointOrder: rig.canonicalLeafNames,
            restLocalTransforms: restTransforms,
            resolution: resolution
        )

        cache[key] = pose

        print(
            """
            [SourceRigRestPoseCache] loaded source rest pose
              resolution: \(resolution)
              url: \(url.path)
              joints: \(restTransforms.count)
            """
        )

        return pose
    }

    private static func transform(
        from restTransform: JockAnimClip.SourceRig.RestLocalTransform
    ) -> Transform {
        Transform(
            scale: SIMD3<Float>(
                Self.value(restTransform.scaleXYZ, at: 0, fallback: 1),
                Self.value(restTransform.scaleXYZ, at: 1, fallback: 1),
                Self.value(restTransform.scaleXYZ, at: 2, fallback: 1)
            ),
            rotation: simd_normalize(
                JockPoseMath.quatFromWXYZ(restTransform.rotationQuatWXYZ)
            ),
            translation: SIMD3<Float>(
                Self.value(restTransform.translationXYZ, at: 0, fallback: 0),
                Self.value(restTransform.translationXYZ, at: 1, fallback: 0),
                Self.value(restTransform.translationXYZ, at: 2, fallback: 0)
            )
        )
    }

    private static func value(
        _ values: [Float],
        at index: Int,
        fallback: Float
    ) -> Float {
        guard values.indices.contains(index) else {
            return fallback
        }

        return values[index]
    }

    private static func firstSkinnedModelEntity(in entity: Entity) -> ModelEntity? {
        if let modelEntity = entity as? ModelEntity,
           !modelEntity.jointNames.isEmpty {
            return modelEntity
        }

        for child in entity.children {
            if let found = firstSkinnedModelEntity(in: child) {
                return found
            }
        }

        return nil
    }
}

enum JockCanonicalRetargetTopology {
    static let chains: [[String]] = [
        ["Hips", "LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase"],
        ["Hips", "RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"],
        ["Hips", "Spine02", "Spine01", "Spine", "neck", "Head", "head_end"],
        ["Spine", "LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
        ["Spine", "RightShoulder", "RightArm", "RightForeArm", "RightHand"]
    ]

    static let debugEdges: [(parent: String, child: String)] = [
        ("Hips", "Spine02"),
        ("Spine02", "Spine01"),
        ("Spine01", "Spine"),
        ("LeftUpLeg", "LeftLeg"),
        ("LeftLeg", "LeftFoot"),
        ("RightUpLeg", "RightLeg"),
        ("RightLeg", "RightFoot")
    ]
}

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
    private let skeletonMappingRecords: [JockJointMappingRecord]
    private let canonicalJointOrder: [String]
    private let parentByCanonicalJoint: [String: String]

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
    private var activeLocomotionPolicy: JockClipLocomotionPolicy = .useClipLocomotion
    private var activeSubAnimations: [ActiveSubAnimation] = []
    private var preparedClipsByID: [String: JockPreparedClip] = [:]
    private var loggedPreservePolicyClipIDs = Set<String>()
    private var loggedPreserveRotationBasisDiagnostics = Set<String>()
    private var loggedDirectionRetargetPolicyClipIDs = Set<String>()
    private var loggedDirectionRetargetRootMotionClipIDs = Set<String>()
    private var loggedDirectionRetargetKneeDiagnostics = Set<String>()
    private var loggedDirectionRetargetEdgeDiagnostics = Set<String>()
    private var loggedSourceRestDeltaDiagnostics = Set<String>()
    private var loggedSourceRestDeltaJointDiagnostics = Set<String>()
    private var preserveTargetJointRotationCorrections: [String: JockJointRotationCorrection] = [:]
    private let directionRetargetIterations = 10
    private let directionRetargetDiagnosticFrames: Set<Int> = [0, 30, 60]
    private let applyNonRootTranslationDeltas = false
    private let ignoreSourceRestRootY = true
    private let maxNonRootTranslationDeltaAsBoneFraction: Float = 0.35
    private let preserveRotationDiagnosticJoints: Set<String> = [
        "Hips",
        "Spine02",
        "Spine01",
        "Spine"
    ]

    private(set) var currentJointTransforms: [Transform]
    private(set) var currentActiveClipID: String?
    private(set) var currentPlaybackTime: TimeInterval = 0
    private(set) var poseApplicationPolicy: JockPoseApplicationPolicy
    private(set) var characterArchetype: PlagueCharacterArchetype

    var matchedJointCount: Int {
        skeletonMappingRecords.filter { record in
            record.matchKind == .exactFullPath ||
                record.matchKind == .uniqueLeafName
        }.count
    }

    var onClipCompleted: ((JockAnimClip) -> Void)?
    var locomotionDeltaHandler: ((JockRuntimeLocomotionDelta) -> Bool)?

    init(
        modelEntity: ModelEntity,
        adapter: JockSkeletonAdapter,
        characterArchetype: PlagueCharacterArchetype = .dad,
        poseApplicationPolicy: JockPoseApplicationPolicy = .authorAbsoluteLocal,
        locomotionRootEntity: Entity? = nil,
        visualOffsetEntity: Entity? = nil
    ) {
        self.modelEntity = modelEntity
        self.adapter = adapter
        self.characterArchetype = characterArchetype
        self.poseApplicationPolicy = poseApplicationPolicy
        self.locomotionRootEntity = locomotionRootEntity
        self.visualOffsetEntity = visualOffsetEntity
        self.baseJointTransforms = modelEntity.jointTransforms
        self.jointNames = modelEntity.jointNames
        self.skeletonMappingRecords = adapter.mappingRecords
        self.canonicalJointOrder = adapter.rig.canonicalLeafNames
        self.parentByCanonicalJoint = Self.buildParentMap(
            jointPaths: adapter.rig.jointPaths
        )
        self.currentJointTransforms = modelEntity.jointTransforms

        print(
            """
            [JockRuntimeDriver] character loaded
              archetype: \(characterArchetype.rawValue)
              asset: \(characterArchetype.usdzFileName)
              poseApplicationPolicy: \(poseApplicationPolicy.rawValue)
              runtimeJointCount: \(jointNames.count)
              baseJointTransforms: \(baseJointTransforms.count)
              matchedJointCount: \(matchedJointCount)
            """
        )

        print(
            """
            [JockRuntimeDriver] canonical joint entity map
              archetype: \(characterArchetype.rawValue)
              Head: \(adapter.runtimeJointName(for: "Head") ?? "nil")
              head_end: \(adapter.runtimeJointName(for: "head_end") ?? "nil")
              headfront: \(adapter.runtimeJointName(for: "headfront") ?? "nil")
              Hips: \(adapter.runtimeJointName(for: "Hips") ?? "nil")
            """
        )

        if poseApplicationPolicy == .preserveTargetSkeleton,
           preserveTargetJointRotationCorrections.isEmpty {
            print("[JockRuntimeDriver] preserve target correction table empty; no hard axis swaps active.")
        }

        if poseApplicationPolicy == .sourceRestDeltaToTargetRest {
            print(
                """
                [JockRuntimeDriver] source-rest delta defaults
                  applyNonRootTranslationDeltas: \(applyNonRootTranslationDeltas)
                  ignoreRootY: \(ignoreSourceRestRootY)
                  maxNonRootTranslationDeltaAsBoneFraction: \(maxNonRootTranslationDeltaAsBoneFraction)
                """
            )
        }
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
        locomotionPolicy: JockClipLocomotionPolicy = .useClipLocomotion,
        runtimeOverride: JockRuntimeClipOverride = .identity
    ) {
        guard let modelEntity else { return }

        activeClip = clip
        activeRuntimeOverride = runtimeOverride
        activeLocomotionPolicy = locomotionPolicy
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
            [Gravitas Jock] playClip
              clipID: \(clip.clipID)
              loop: \(loop)
              locomotionPolicy: \(locomotionPolicy)
              runtimeOverrideEntry: \(runtimeOverride.entryHeadingDegrees)
              runtimeOverrideExit: \(runtimeOverride.exitHeadingDegrees)
              commitYaw: \(runtimeOverride.commitRootYawOnCompletion)
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
        activeLocomotionPolicy = .useClipLocomotion
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
        activeLocomotionPolicy = .useClipLocomotion
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
        activeLocomotionPolicy = .useClipLocomotion
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
                activeLocomotionPolicy = .useClipLocomotion
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
                    activeRuntimeOverride = .identity
                    activeLocomotionPolicy = .useClipLocomotion

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
                keys: sortedKeys,
                sourceReferenceTranslation: Self.sourceReferenceTranslation(
                    channel: track.channel,
                    keys: sortedKeys
                ),
                sourceReferenceRotation: Self.sourceReferenceRotation(
                    channel: track.channel,
                    keys: sortedKeys
                ),
                sourceReferenceScale: Self.sourceReferenceScale(
                    channel: track.channel,
                    keys: sortedKeys
                )
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
        switch poseApplicationPolicy {
        case .authorAbsoluteLocal:
            return sampleClipPoseAuthorAbsoluteLocal(
                clip,
                preparedTracks: preparedTracks,
                at: time
            )

        case .preserveTargetSkeleton:
            return sampleClipPosePreservingTargetSkeleton(
                clip,
                preparedTracks: preparedTracks,
                at: time
            )

        case .preserveTargetSkeletonDirectionRetarget:
            if clip.isSubAnimationOverride {
                return sampleClipPosePreservingTargetSkeleton(
                    clip,
                    preparedTracks: preparedTracks,
                    at: time
                )
            }

            return sampleClipPosePreservingTargetSkeletonDirectionRetarget(
                clip,
                preparedTracks: preparedTracks,
                at: time
            )

        case .sourceRestDeltaToTargetRest:
            return sampleClipPoseSourceRestDeltaToTargetRest(
                clip,
                preparedTracks: preparedTracks,
                at: time
            )
        }
    }

    private func sampleClipPoseAuthorAbsoluteLocal(
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

    private func sampleClipPosePreservingTargetSkeleton(
        _ clip: JockAnimClip,
        preparedTracks: [JockPreparedTrack],
        at time: TimeInterval
    ) -> [Transform] {
        logPreserveTargetSkeletonDiagnosticsIfNeeded(
            clip: clip,
            preparedTracks: preparedTracks
        )

        var output = baseJointTransforms

        for track in preparedTracks {
            guard output.indices.contains(track.runtimeIndex) else {
                continue
            }

            var transform = output[track.runtimeIndex]
            let isRoot = isRootTranslationJoint(track.joint)

            switch track.channel {
            case "translation_xyz_additive":
                guard isRoot else {
                    continue
                }

                let offset = JockPoseMath.sampleVector3Sorted(keys: track.keys, time: time)
                transform.translation = baseJointTransforms[track.runtimeIndex].translation + offset

            case "rotation_quat_wxyz_additive":
                let delta = JockPoseMath.sampleQuaternionWXYZSorted(keys: track.keys, time: time)
                transform.rotation = simd_normalize(transform.rotation * simd_normalize(delta))

            case "rotation_euler_xyz_degrees_additive":
                let delta = JockPoseMath.sampleEulerXYZDegreesAsQuaternionSorted(keys: track.keys, time: time)
                transform.rotation = simd_normalize(transform.rotation * simd_normalize(delta))

            case "translation_xyz_absolute":
                guard isRoot else {
                    continue
                }

                let sampled = JockPoseMath.sampleVector3Sorted(keys: track.keys, time: time)
                let reference = track.sourceReferenceTranslation ?? sampled
                transform.translation = baseJointTransforms[track.runtimeIndex].translation + (sampled - reference)

            case "rotation_quat_wxyz_absolute":
                let sampled = simd_normalize(
                    JockPoseMath.sampleQuaternionWXYZSorted(keys: track.keys, time: time)
                )
                let reference = simd_normalize(track.sourceReferenceRotation ?? sampled)
                let parentSpaceDelta = simd_normalize(sampled * simd_inverse(reference))

                transform.rotation = simd_normalize(
                    parentSpaceDelta * baseJointTransforms[track.runtimeIndex].rotation
                )

                if let correction = preserveTargetJointRotationCorrections[track.joint] {
                    transform.rotation = simd_normalize(
                        correction.post * transform.rotation * correction.pre
                    )
                }

                logPreserveRotationBasisDiagnosticsIfNeeded(
                    clip: clip,
                    jointName: track.joint,
                    targetBase: baseJointTransforms[track.runtimeIndex],
                    sampledRotation: sampled,
                    referenceRotation: reference,
                    parentSpaceDelta: parentSpaceDelta,
                    finalRotation: transform.rotation
                )

            case "scale_xyz_absolute":
                continue

            default:
                continue
            }

            output[track.runtimeIndex] = transform
        }

        return output
    }

    private func sampleClipPoseSourceRestDeltaToTargetRest(
        _ clip: JockAnimClip,
        preparedTracks: [JockPreparedTrack],
        at time: TimeInterval
    ) -> [Transform] {
        let sourceRest: SourceRigRestPose

        do {
            sourceRest = try SourceRigRestPoseCache.shared.resolve(
                clip: clip,
                rig: adapter.rig,
                defaultDadUSDZURL: CharacterAssetRegistry.url(for: .dad)
            )
        } catch {
            print(
                """
                [JockRuntimeDriver] ERROR source-rest delta retarget unavailable
                  archetype: \(characterArchetype.rawValue)
                  clip: \(clip.clipID)
                  error: \(error.localizedDescription)
                """
            )

            return baseJointTransforms
        }

        let groupedTracks = preparedTracksByJointAndChannel(preparedTracks)
        let targetRestLocal = localTransformsByCanonicalJoint(
            from: baseJointTransforms
        )
        let sourceAnimatedLocal = sampleSourceAnimatedLocalTransforms(
            sourceRest: sourceRest,
            groupedTracks: groupedTracks,
            time: time
        )
        let sourceRestGlobals = computeGlobalTransforms(
            localTransforms: sourceRest.restLocalTransforms,
            jointOrder: sourceRest.jointOrder,
            parentByJoint: parentByCanonicalJoint
        )
        let sourceAnimatedGlobals = computeGlobalTransforms(
            localTransforms: sourceAnimatedLocal,
            jointOrder: sourceRest.jointOrder,
            parentByJoint: parentByCanonicalJoint
        )
        let targetRestGlobals = computeGlobalTransforms(
            localTransforms: targetRestLocal,
            jointOrder: canonicalJointOrder,
            parentByJoint: parentByCanonicalJoint
        )
        let sourceHeight = max(
            bodyHeight(from: sourceRestGlobals),
            0.001
        )
        let targetHeight = max(
            bodyHeight(from: targetRestGlobals),
            0.001
        )
        let sourceToTargetScale = targetHeight / sourceHeight

        logSourceRestDeltaDiagnosticsIfNeeded(
            clip: clip,
            sourceRest: sourceRest,
            sourceHeight: sourceHeight,
            targetHeight: targetHeight,
            sourceToTargetScale: sourceToTargetScale,
            groupedTracks: groupedTracks
        )

        var output = baseJointTransforms
        var outputGlobals: [String: GlobalJointTransform] = [:]

        for joint in canonicalJointOrder {
            guard let runtimeIndex = adapter.runtimeIndex(for: joint),
                  output.indices.contains(runtimeIndex) else {
                continue
            }

            let targetBase = baseJointTransforms[runtimeIndex]
            var targetOutput = targetBase

            if let sourceRestGlobal = sourceRestGlobals[joint],
               let sourceAnimatedGlobal = sourceAnimatedGlobals[joint],
               let targetRestGlobal = targetRestGlobals[joint] {
                let sourceDeltaGlobalRotation = simd_normalize(
                    sourceAnimatedGlobal.rotation *
                        simd_inverse(sourceRestGlobal.rotation)
                )
                let desiredTargetGlobalRotation = simd_normalize(
                    sourceDeltaGlobalRotation * targetRestGlobal.rotation
                )

                if let parent = parentByCanonicalJoint[joint],
                   let parentGlobal = outputGlobals[parent] {
                    targetOutput.rotation = simd_normalize(
                        simd_inverse(parentGlobal.rotation) *
                            desiredTargetGlobalRotation
                    )
                } else {
                    targetOutput.rotation = desiredTargetGlobalRotation
                }
            }

            if let translationTrack = groupedTracks[joint]?["translation_xyz_absolute"] {
                let sampledTranslation = JockPoseMath.sampleVector3Sorted(
                    keys: translationTrack.keys,
                    time: time
                )
                let sourceBaseTranslation =
                    sourceRest.restLocalTransforms[joint]?.translation ??
                    sampledTranslation
                var rawDelta = sampledTranslation - sourceBaseTranslation

                if isRootTranslationJoint(joint) {
                    if ignoreSourceRestRootY {
                        rawDelta.y = 0
                    }

                    targetOutput.translation = targetBase.translation +
                        convertLocalTranslationDelta(
                            rawDelta,
                            joint: joint,
                            sourceRestGlobals: sourceRestGlobals,
                            targetRestGlobals: targetRestGlobals,
                            scale: sourceToTargetScale
                        )
                } else if applyNonRootTranslationDeltas {
                    let convertedDelta = convertLocalTranslationDelta(
                        rawDelta,
                        joint: joint,
                        sourceRestGlobals: sourceRestGlobals,
                        targetRestGlobals: targetRestGlobals,
                        scale: sourceToTargetScale
                    )
                    let clampedDelta = clampNonRootTranslationDeltaIfNeeded(
                        convertedDelta,
                        joint: joint,
                        targetBase: targetBase
                    )

                    targetOutput.translation = targetBase.translation + clampedDelta
                } else {
                    targetOutput.translation = targetBase.translation
                }

                logSourceRestDeltaJointDiagnosticsIfNeeded(
                    clip: clip,
                    joint: joint,
                    sourceBaseTranslation: sourceBaseTranslation,
                    sampledTranslation: sampledTranslation,
                    rawDelta: rawDelta,
                    targetBaseTranslation: targetBase.translation,
                    finalTargetTranslation: targetOutput.translation,
                    sourceRestGlobal: sourceRestGlobals[joint],
                    sourceAnimatedGlobal: sourceAnimatedGlobals[joint],
                    targetRestGlobal: targetRestGlobals[joint],
                    finalLocalRotation: targetOutput.rotation
                )
            }

            targetOutput.scale = targetBase.scale
            output[runtimeIndex] = targetOutput

            outputGlobals[joint] = computeSingleGlobalTransform(
                joint: joint,
                local: targetOutput,
                outputGlobals: outputGlobals
            )
        }

        return output
    }

    private func sampleClipPosePreservingTargetSkeletonDirectionRetarget(
        _ clip: JockAnimClip,
        preparedTracks: [JockPreparedTrack],
        at time: TimeInterval
    ) -> [Transform] {
        let sourceReferenceLocal = sampleSourceLocalTransforms(
            preparedTracks: preparedTracks,
            at: 0
        )
        let sourceAnimatedLocal = sampleSourceLocalTransforms(
            preparedTracks: preparedTracks,
            at: time
        )
        let sourceReferencePose = makeWorldPose(
            from: sourceReferenceLocal,
            time: 0
        )
        let sourceAnimatedPose = makeWorldPose(
            from: sourceAnimatedLocal,
            time: time
        )
        let targetBaseLocal = localTransformsByCanonicalJoint(
            from: baseJointTransforms
        )
        let targetBaseWorldPose = makeWorldPose(
            from: targetBaseLocal,
            time: 0
        )
        let basisMap = solveSourceToTargetBodyBasisMap(
            sourceReferencePose: sourceReferencePose,
            targetBaseWorldPose: targetBaseWorldPose
        )

        logDirectionRetargetPolicyDiagnosticsIfNeeded(
            clip: clip,
            preparedTracks: preparedTracks,
            basisMap: basisMap
        )

        var output = baseJointTransforms

        applyRootMotionDirectionRetarget(
            to: &output,
            clip: clip,
            sourceReferencePose: sourceReferencePose,
            sourceAnimatedPose: sourceAnimatedPose,
            targetBaseWorldPose: targetBaseWorldPose,
            basisMap: basisMap
        )

        for _ in 0..<directionRetargetIterations {
            for chain in JockCanonicalRetargetTopology.chains {
                solveConnectedChainDirections(
                    chain,
                    output: &output,
                    clip: clip,
                    time: time,
                    sourceAnimatedPose: sourceAnimatedPose,
                    basisMap: basisMap
                )
            }
        }

        applyTargetGroundCompensation(
            to: &output,
            clip: clip,
            targetBaseWorldPose: targetBaseWorldPose
        )

        let targetSolvedPose = makeWorldPose(
            from: localTransformsByCanonicalJoint(from: output),
            time: time
        )

        logKneeBendDiagnosticsIfNeeded(
            clip: clip,
            time: time,
            sourceAnimatedPose: sourceAnimatedPose,
            targetPose: targetSolvedPose
        )

        return output
    }

    private func preparedTracksByJointAndChannel(
        _ preparedTracks: [JockPreparedTrack]
    ) -> [String: [String: JockPreparedTrack]] {
        preparedTracks.reduce(into: [String: [String: JockPreparedTrack]]()) { partial, track in
            partial[track.joint, default: [:]][track.channel] = track
        }
    }

    private func sampleSourceAnimatedLocalTransforms(
        sourceRest: SourceRigRestPose,
        groupedTracks: [String: [String: JockPreparedTrack]],
        time: TimeInterval
    ) -> [String: Transform] {
        var locals = sourceRest.restLocalTransforms

        for joint in sourceRest.jointOrder {
            var transform = locals[joint] ?? Self.identityTransform()
            let channels = groupedTracks[joint] ?? [:]

            if let track = channels["translation_xyz_absolute"] {
                transform.translation = JockPoseMath.sampleVector3Sorted(
                    keys: track.keys,
                    time: time
                )
            }

            if let track = channels["rotation_quat_wxyz_absolute"] {
                transform.rotation = simd_normalize(
                    JockPoseMath.sampleQuaternionWXYZSorted(
                        keys: track.keys,
                        time: time
                    )
                )
            }

            if let track = channels["scale_xyz_absolute"] {
                transform.scale = JockPoseMath.sampleVector3Sorted(
                    keys: track.keys,
                    time: time
                )
            }

            if let track = channels["translation_xyz_additive"] {
                transform.translation += JockPoseMath.sampleVector3Sorted(
                    keys: track.keys,
                    time: time
                )
            }

            if let track = channels["rotation_quat_wxyz_additive"] {
                let delta = JockPoseMath.sampleQuaternionWXYZSorted(
                    keys: track.keys,
                    time: time
                )
                transform.rotation = simd_normalize(
                    transform.rotation * simd_normalize(delta)
                )
            }

            if let track = channels["rotation_euler_xyz_degrees_additive"] {
                let delta = JockPoseMath.sampleEulerXYZDegreesAsQuaternionSorted(
                    keys: track.keys,
                    time: time
                )
                transform.rotation = simd_normalize(
                    transform.rotation * simd_normalize(delta)
                )
            }

            locals[joint] = transform
        }

        return locals
    }

    private func computeGlobalTransforms(
        localTransforms: [String: Transform],
        jointOrder: [String],
        parentByJoint: [String: String]
    ) -> [String: GlobalJointTransform] {
        var globalMatrices: [String: simd_float4x4] = [:]
        var globals: [String: GlobalJointTransform] = [:]

        for joint in jointOrder {
            let localMatrix = (localTransforms[joint] ?? Self.identityTransform()).matrix
            let globalMatrix: simd_float4x4

            if let parent = parentByJoint[joint],
               let parentMatrix = globalMatrices[parent] {
                globalMatrix = parentMatrix * localMatrix
            } else {
                globalMatrix = localMatrix
            }

            globalMatrices[joint] = globalMatrix
            globals[joint] = Self.globalJointTransform(from: globalMatrix)
        }

        return globals
    }

    private func computeSingleGlobalTransform(
        joint: String,
        local: Transform,
        outputGlobals: [String: GlobalJointTransform]
    ) -> GlobalJointTransform {
        let localMatrix = local.matrix
        let globalMatrix: simd_float4x4

        if let parent = parentByCanonicalJoint[joint],
           let parentGlobal = outputGlobals[parent] {
            globalMatrix = Self.matrix(from: parentGlobal) * localMatrix
        } else {
            globalMatrix = localMatrix
        }

        return Self.globalJointTransform(from: globalMatrix)
    }

    private func convertLocalTranslationDelta(
        _ delta: SIMD3<Float>,
        joint: String,
        sourceRestGlobals: [String: GlobalJointTransform],
        targetRestGlobals: [String: GlobalJointTransform],
        scale: Float
    ) -> SIMD3<Float> {
        guard let parent = parentByCanonicalJoint[joint],
              let sourceParent = sourceRestGlobals[parent],
              let targetParent = targetRestGlobals[parent] else {
            return delta * scale
        }

        let worldDelta = sourceParent.rotation.act(delta)
        let targetLocalDelta = simd_inverse(targetParent.rotation).act(worldDelta)

        return targetLocalDelta * scale
    }

    private func clampNonRootTranslationDeltaIfNeeded(
        _ delta: SIMD3<Float>,
        joint: String,
        targetBase: Transform
    ) -> SIMD3<Float> {
        let targetBoneLength = max(
            simd_length(targetBase.translation),
            0.001
        )
        let maxLength = targetBoneLength * maxNonRootTranslationDeltaAsBoneFraction
        let length = simd_length(delta)

        guard length > maxLength else {
            return delta
        }

        let clamped = Self.normalizeSafe(
            delta,
            fallback: .zero
        ) * maxLength

        print(
            """
            [JockRuntimeDriver] source-rest delta non-root translation clamped
              archetype: \(characterArchetype.rawValue)
              joint: \(joint)
              originalLength: \(length)
              maxLength: \(maxLength)
            """
        )

        return clamped
    }

    private func bodyHeight(
        from globals: [String: GlobalJointTransform]
    ) -> Float {
        guard let hips = globals["Hips"]?.translation else {
            return 1
        }

        let top =
            globals["Head"]?.translation ??
            globals["neck"]?.translation ??
            globals["Spine"]?.translation

        guard let top else {
            return 1
        }

        return max(simd_length(top - hips), 0.001)
    }

    private func logSourceRestDeltaDiagnosticsIfNeeded(
        clip: JockAnimClip,
        sourceRest: SourceRigRestPose,
        sourceHeight: Float,
        targetHeight: Float,
        sourceToTargetScale: Float,
        groupedTracks: [String: [String: JockPreparedTrack]]
    ) {
        let key = "\(characterArchetype.rawValue)|\(clip.clipID)|sourceRestDelta"

        guard !loggedSourceRestDeltaDiagnostics.contains(key) else {
            return
        }

        loggedSourceRestDeltaDiagnostics.insert(key)

        let rotationTracks = groupedTracks.values.filter { channels in
            channels["rotation_quat_wxyz_absolute"] != nil
        }.count
        let rootTranslationTracks = groupedTracks.filter { pair in
            pair.value["translation_xyz_absolute"] != nil &&
                isRootTranslationJoint(pair.key)
        }.count
        let nonRootTranslationTracks = groupedTracks.filter { pair in
            pair.value["translation_xyz_absolute"] != nil &&
                !isRootTranslationJoint(pair.key)
        }.count

        print(
            """
            [JockRuntimeDriver] source-rest delta retarget
              archetype: \(characterArchetype.rawValue)
              clip: \(clip.clipID)
              policy: \(poseApplicationPolicy.rawValue)
              sourceRestResolution: \(sourceRest.resolution)
              sourceCharacterID: \(sourceRest.characterID)
              sourceSkeletonHash: \(sourceRest.skeletonHash)
              targetCharacterID: \(characterArchetype.rawValue)
              sourceRestJoints: \(sourceRest.restLocalTransforms.count)
              targetRestJoints: \(canonicalJointOrder.count)
              rotationMode: globalRestBasis
              translationMode: sourceBaseDelta
              applyNonRootTranslationDeltas: \(applyNonRootTranslationDeltas)
              ignoreRootY: \(ignoreSourceRestRootY)
              sourceHeight: \(sourceHeight)
              targetHeight: \(targetHeight)
              sourceToTargetScale: \(sourceToTargetScale)
              rotationTracks: \(rotationTracks)
              rootTranslationTracks: \(rootTranslationTracks)
              nonRootTranslationTracksSeen: \(nonRootTranslationTracks)
            """
        )
    }

    private func logSourceRestDeltaJointDiagnosticsIfNeeded(
        clip: JockAnimClip,
        joint: String,
        sourceBaseTranslation: SIMD3<Float>,
        sampledTranslation: SIMD3<Float>,
        rawDelta: SIMD3<Float>,
        targetBaseTranslation: SIMD3<Float>,
        finalTargetTranslation: SIMD3<Float>,
        sourceRestGlobal: GlobalJointTransform?,
        sourceAnimatedGlobal: GlobalJointTransform?,
        targetRestGlobal: GlobalJointTransform?,
        finalLocalRotation: simd_quatf
    ) {
        let debugJoints: Set<String> = [
            "Hips",
            "Spine02",
            "Spine01",
            "Spine",
            "LeftUpLeg",
            "LeftLeg",
            "RightUpLeg",
            "RightLeg"
        ]

        guard debugJoints.contains(joint) else {
            return
        }

        let key = "\(characterArchetype.rawValue)|\(clip.clipID)|\(joint)|sourceRestDelta"

        guard !loggedSourceRestDeltaJointDiagnostics.contains(key) else {
            return
        }

        loggedSourceRestDeltaJointDiagnostics.insert(key)

        print(
            """
            [JockRuntimeDriver] source-rest delta joint diagnostic
              archetype: \(characterArchetype.rawValue)
              clip: \(clip.clipID)
              joint: \(joint)
              sourceBaseT: \(sourceBaseTranslation)
              sampledT: \(sampledTranslation)
              sourceDeltaT: \(rawDelta)
              targetBaseT: \(targetBaseTranslation)
              finalTargetT: \(finalTargetTranslation)
              sourceRestGlobalR: \(sourceRestGlobal?.rotation.vector ?? SIMD4<Float>(0, 0, 0, 1))
              sourceAnimGlobalR: \(sourceAnimatedGlobal?.rotation.vector ?? SIMD4<Float>(0, 0, 0, 1))
              sourceDeltaGlobalR: \(sourceDeltaRotationVector(sourceRestGlobal: sourceRestGlobal, sourceAnimatedGlobal: sourceAnimatedGlobal))
              targetRestGlobalR: \(targetRestGlobal?.rotation.vector ?? SIMD4<Float>(0, 0, 0, 1))
              finalLocalR: \(finalLocalRotation.vector)
            """
        )
    }

    private func sourceDeltaRotationVector(
        sourceRestGlobal: GlobalJointTransform?,
        sourceAnimatedGlobal: GlobalJointTransform?
    ) -> SIMD4<Float> {
        guard let sourceRestGlobal,
              let sourceAnimatedGlobal else {
            return SIMD4<Float>(0, 0, 0, 1)
        }

        return simd_normalize(
            sourceAnimatedGlobal.rotation *
                simd_inverse(sourceRestGlobal.rotation)
        ).vector
    }

    private func sampleSourceLocalTransforms(
        preparedTracks: [JockPreparedTrack],
        at time: TimeInterval
    ) -> [String: Transform] {
        var localByJoint: [String: Transform] = [:]

        for joint in canonicalJointOrder {
            localByJoint[joint] = Self.identityTransform()
        }

        for track in preparedTracks {
            var transform = localByJoint[track.joint] ?? Self.identityTransform()

            switch track.channel {
            case "translation_xyz_additive":
                transform.translation += JockPoseMath.sampleVector3Sorted(
                    keys: track.keys,
                    time: time
                )

            case "rotation_quat_wxyz_additive":
                let delta = JockPoseMath.sampleQuaternionWXYZSorted(
                    keys: track.keys,
                    time: time
                )
                transform.rotation = simd_normalize(transform.rotation * simd_normalize(delta))

            case "rotation_euler_xyz_degrees_additive":
                let delta = JockPoseMath.sampleEulerXYZDegreesAsQuaternionSorted(
                    keys: track.keys,
                    time: time
                )
                transform.rotation = simd_normalize(transform.rotation * simd_normalize(delta))

            case "translation_xyz_absolute":
                transform.translation = JockPoseMath.sampleVector3Sorted(
                    keys: track.keys,
                    time: time
                )

            case "rotation_quat_wxyz_absolute":
                transform.rotation = simd_normalize(
                    JockPoseMath.sampleQuaternionWXYZSorted(
                        keys: track.keys,
                        time: time
                    )
                )

            case "scale_xyz_absolute":
                transform.scale = JockPoseMath.sampleVector3Sorted(
                    keys: track.keys,
                    time: time
                )

            default:
                continue
            }

            localByJoint[track.joint] = transform
        }

        return localByJoint
    }

    private func localTransformsByCanonicalJoint(
        from transforms: [Transform]
    ) -> [String: Transform] {
        var localByJoint: [String: Transform] = [:]

        for joint in canonicalJointOrder {
            if let index = adapter.runtimeIndex(for: joint),
               transforms.indices.contains(index) {
                localByJoint[joint] = transforms[index]
            } else {
                localByJoint[joint] = Self.identityTransform()
            }
        }

        return localByJoint
    }

    private func makeWorldPose(
        from localByJoint: [String: Transform],
        time: TimeInterval
    ) -> JockWorldPose {
        var worldMatrices: [String: simd_float4x4] = [:]
        var worldJoints: [String: JockWorldJointPose] = [:]

        for joint in canonicalJointOrder {
            let local = localByJoint[joint] ?? Self.identityTransform()
            let localMatrix = local.matrix
            let worldMatrix: simd_float4x4

            if let parent = parentByCanonicalJoint[joint],
               let parentMatrix = worldMatrices[parent] {
                worldMatrix = parentMatrix * localMatrix
            } else {
                worldMatrix = localMatrix
            }

            worldMatrices[joint] = worldMatrix

            let worldPosition = SIMD3<Float>(
                worldMatrix.columns.3.x,
                worldMatrix.columns.3.y,
                worldMatrix.columns.3.z
            )

            worldJoints[joint] = JockWorldJointPose(
                jointName: joint,
                worldPosition: worldPosition,
                worldRotation: simd_normalize(
                    simd_quatf(Self.rotationMatrix(from: worldMatrix))
                )
            )
        }

        return JockWorldPose(
            frameTimeSeconds: time,
            joints: worldJoints
        )
    }

    private func solveSourceToTargetBodyBasisMap(
        sourceReferencePose: JockWorldPose,
        targetBaseWorldPose: JockWorldPose
    ) -> SourceToTargetBodyBasisMap {
        guard let sourceBasis = bodyBasis(from: sourceReferencePose),
              let targetBasis = bodyBasis(from: targetBaseWorldPose) else {
            return SourceToTargetBodyBasisMap(
                valid: false,
                rotation: Self.identityQuaternion()
            )
        }

        let rotationMatrix = targetBasis * sourceBasis.transpose

        return SourceToTargetBodyBasisMap(
            valid: true,
            rotation: simd_normalize(simd_quatf(rotationMatrix))
        )
    }

    private func bodyBasis(
        from pose: JockWorldPose
    ) -> simd_float3x3? {
        guard let hips = pose.joints["Hips"]?.worldPosition else {
            return nil
        }

        let upper =
            pose.joints["Spine"]?.worldPosition ??
            pose.joints["neck"]?.worldPosition ??
            pose.joints["Head"]?.worldPosition

        let left =
            pose.joints["LeftArm"]?.worldPosition ??
            pose.joints["LeftShoulder"]?.worldPosition ??
            pose.joints["LeftUpLeg"]?.worldPosition

        let right =
            pose.joints["RightArm"]?.worldPosition ??
            pose.joints["RightShoulder"]?.worldPosition ??
            pose.joints["RightUpLeg"]?.worldPosition

        guard let upper,
              let left,
              let right else {
            return nil
        }

        let up = Self.normalizeSafe(
            upper - hips,
            fallback: SIMD3<Float>(0, 1, 0)
        )
        let rightAxis = Self.normalizeSafe(
            right - left,
            fallback: SIMD3<Float>(1, 0, 0)
        )
        let forward = Self.normalizeSafe(
            simd_cross(rightAxis, up),
            fallback: SIMD3<Float>(0, 0, 1)
        )
        let cleanRight = Self.normalizeSafe(
            simd_cross(up, forward),
            fallback: rightAxis
        )

        return simd_float3x3(
            cleanRight,
            up,
            forward
        )
    }

    private func applyRootMotionDirectionRetarget(
        to output: inout [Transform],
        clip: JockAnimClip,
        sourceReferencePose: JockWorldPose,
        sourceAnimatedPose: JockWorldPose,
        targetBaseWorldPose: JockWorldPose,
        basisMap: SourceToTargetBodyBasisMap
    ) {
        guard let rootIndex = adapter.runtimeIndex(for: "Hips"),
              output.indices.contains(rootIndex),
              let sourceReferenceHips = sourceReferencePose.joints["Hips"]?.worldPosition,
              let sourceAnimatedHips = sourceAnimatedPose.joints["Hips"]?.worldPosition else {
            return
        }

        var sourceDelta = sourceAnimatedHips - sourceReferenceHips
        sourceDelta.y = 0

        var mappedDelta = basisMap.valid
            ? basisMap.rotation.act(sourceDelta)
            : sourceDelta
        mappedDelta.y = 0

        let sourceHeight = max(bodyHeight(in: sourceReferencePose), 0.001)
        let targetHeight = max(bodyHeight(in: targetBaseWorldPose), 0.001)
        let heightScale = targetHeight / sourceHeight
        let scaledDelta = mappedDelta * heightScale

        output[rootIndex].translation =
            baseJointTransforms[rootIndex].translation + scaledDelta

        logDirectionRetargetRootMotionIfNeeded(
            clip: clip,
            sourceDelta: sourceDelta,
            mappedDelta: mappedDelta,
            scaledDelta: scaledDelta,
            heightScale: heightScale
        )
    }

    private func solveConnectedChainDirections(
        _ chain: [String],
        output: inout [Transform],
        clip: JockAnimClip,
        time: TimeInterval,
        sourceAnimatedPose: JockWorldPose,
        basisMap: SourceToTargetBodyBasisMap
    ) {
        guard chain.count >= 2 else {
            return
        }

        for index in 0..<(chain.count - 1) {
            let parentName = chain[index]
            let childName = chain[index + 1]

            // Keep global body orientation owned by gameplay/root logic.
            guard !isRootTranslationJoint(parentName) else {
                continue
            }

            guard let parentRuntimeIndex = adapter.runtimeIndex(for: parentName),
                  output.indices.contains(parentRuntimeIndex),
                  let sourceParent = sourceAnimatedPose.joints[parentName]?.worldPosition,
                  let sourceChild = sourceAnimatedPose.joints[childName]?.worldPosition else {
                continue
            }

            var worldPose = makeWorldPose(
                from: localTransformsByCanonicalJoint(from: output),
                time: time
            )

            guard let parentWorld = worldPose.joints[parentName],
                  let childWorld = worldPose.joints[childName] else {
                continue
            }

            let sourceAnimatedDir = Self.normalizeSafe(
                sourceChild - sourceParent,
                fallback: SIMD3<Float>(0, 1, 0)
            )
            let desiredTargetDir = Self.normalizeSafe(
                basisMap.valid
                    ? basisMap.rotation.act(sourceAnimatedDir)
                    : sourceAnimatedDir,
                fallback: sourceAnimatedDir
            )
            let currentTargetDir = Self.normalizeSafe(
                childWorld.worldPosition - parentWorld.worldPosition,
                fallback: desiredTargetDir
            )
            let deltaWorld = Self.rotationBetween(
                from: currentTargetDir,
                to: desiredTargetDir
            )
            let parentParentRotation: simd_quatf

            if let grandparent = parentByCanonicalJoint[parentName],
               let grandparentPose = worldPose.joints[grandparent] {
                parentParentRotation = grandparentPose.worldRotation
            } else {
                parentParentRotation = Self.identityQuaternion()
            }

            let localDelta = simd_normalize(
                simd_inverse(parentParentRotation) * deltaWorld * parentParentRotation
            )

            output[parentRuntimeIndex].rotation = simd_normalize(
                localDelta * output[parentRuntimeIndex].rotation
            )

            worldPose = makeWorldPose(
                from: localTransformsByCanonicalJoint(from: output),
                time: time
            )

            if JockCanonicalRetargetTopology.debugEdges.contains(where: { edge in
                edge.parent == parentName && edge.child == childName
            }),
               let updatedParent = worldPose.joints[parentName],
               let updatedChild = worldPose.joints[childName] {
                let currentAfter = Self.normalizeSafe(
                    updatedChild.worldPosition - updatedParent.worldPosition,
                    fallback: desiredTargetDir
                )
                logDirectionRetargetEdgeIfNeeded(
                    clip: clip,
                    time: time,
                    parentName: parentName,
                    childName: childName,
                    sourceAnimatedDir: sourceAnimatedDir,
                    desiredTargetDir: desiredTargetDir,
                    currentTargetDirAfter: currentAfter
                )
            }
        }
    }

    private func applyTargetGroundCompensation(
        to output: inout [Transform],
        clip: JockAnimClip,
        targetBaseWorldPose: JockWorldPose
    ) {
        let groundJoints = [
            "LeftFoot",
            "RightFoot",
            "LeftToeBase",
            "RightToeBase"
        ]

        let currentWorldPose = makeWorldPose(
            from: localTransformsByCanonicalJoint(from: output),
            time: 0
        )

        let baseMinY = groundJoints.compactMap { joint in
            targetBaseWorldPose.joints[joint]?.worldPosition.y
        }.min()

        let currentMinY = groundJoints.compactMap { joint in
            currentWorldPose.joints[joint]?.worldPosition.y
        }.min()

        guard let baseMinY,
              let currentMinY,
              let rootIndex = adapter.runtimeIndex(for: "Hips"),
              output.indices.contains(rootIndex) else {
            return
        }

        let deltaY = baseMinY - currentMinY

        guard abs(deltaY) > 0.002 else {
            return
        }

        output[rootIndex].translation.y += deltaY

        print(
            """
            [JockRuntimeDriver] ground compensation
              archetype: \(characterArchetype.rawValue)
              clip: \(clip.clipID)
              baseMinY: \(baseMinY)
              currentMinY: \(currentMinY)
              deltaY: \(deltaY)
            """
        )
    }

    private static func sourceReferenceTranslation(
        channel: String,
        keys: [JockAnimClip.Key]
    ) -> SIMD3<Float>? {
        guard channel.contains("translation"),
              let first = keys.first else {
            return nil
        }

        return SIMD3<Float>(
            value(first.value, at: 0, fallback: 0),
            value(first.value, at: 1, fallback: 0),
            value(first.value, at: 2, fallback: 0)
        )
    }

    private static func sourceReferenceRotation(
        channel: String,
        keys: [JockAnimClip.Key]
    ) -> simd_quatf? {
        guard channel.contains("rotation"),
              let first = keys.first else {
            return nil
        }

        if channel.contains("quat_wxyz") {
            return simd_normalize(JockPoseMath.quatFromWXYZ(first.value))
        }

        if channel.contains("euler_xyz_degrees") {
            return simd_normalize(
                JockPoseMath.quatFromEulerXYZDegrees(
                    SIMD3<Float>(
                        value(first.value, at: 0, fallback: 0),
                        value(first.value, at: 1, fallback: 0),
                        value(first.value, at: 2, fallback: 0)
                    )
                )
            )
        }

        return nil
    }

    private static func sourceReferenceScale(
        channel: String,
        keys: [JockAnimClip.Key]
    ) -> SIMD3<Float>? {
        guard channel.contains("scale"),
              let first = keys.first else {
            return nil
        }

        return SIMD3<Float>(
            value(first.value, at: 0, fallback: 1),
            value(first.value, at: 1, fallback: 1),
            value(first.value, at: 2, fallback: 1)
        )
    }

    private static func value(
        _ values: [Float],
        at index: Int,
        fallback: Float
    ) -> Float {
        guard values.indices.contains(index) else {
            return fallback
        }

        return values[index]
    }

    private func isRootTranslationJoint(_ jointName: String) -> Bool {
        let lower = jointName.lowercased()

        return lower == "hips" ||
            lower == "root" ||
            lower == "armature" ||
            lower == "pelvis"
    }

    private func bodyHeight(in pose: JockWorldPose) -> Float {
        guard let hips = pose.joints["Hips"]?.worldPosition else {
            return 1
        }

        let top =
            pose.joints["Head"]?.worldPosition ??
            pose.joints["neck"]?.worldPosition ??
            pose.joints["Spine"]?.worldPosition

        guard let top else {
            return 1
        }

        return max(simd_length(top - hips), 0.001)
    }

    private func logDirectionRetargetPolicyDiagnosticsIfNeeded(
        clip: JockAnimClip,
        preparedTracks: [JockPreparedTrack],
        basisMap: SourceToTargetBodyBasisMap
    ) {
        guard !loggedDirectionRetargetPolicyClipIDs.contains(clip.clipID) else {
            return
        }

        loggedDirectionRetargetPolicyClipIDs.insert(clip.clipID)

        let rootTranslationTracksApplied = preparedTracks.filter { track in
            track.channel == "translation_xyz_absolute" &&
                isRootTranslationJoint(track.joint)
        }.count

        let nonRootTranslationTracksIgnored = preparedTracks.filter { track in
            track.channel == "translation_xyz_absolute" &&
                !isRootTranslationJoint(track.joint)
        }.count

        let absoluteRotationTracksRead = preparedTracks.filter { track in
            track.channel == "rotation_quat_wxyz_absolute"
        }.count

        print(
            """
            [JockRuntimeDriver] direction retarget policy diagnostics
              archetype: \(characterArchetype.rawValue)
              clipID: \(clip.clipID)
              poseApplicationPolicy: \(poseApplicationPolicy.rawValue)
              runtimeJointCount: \(jointNames.count)
              matchedJointCount: \(matchedJointCount)
              animationTrackJoints: \(Set(preparedTracks.map(\.joint)).count)
              absoluteRotationTracksRead: \(absoluteRotationTracksRead)
              rootTranslationTracksAppliedHorizontally: \(rootTranslationTracksApplied)
              nonRootTranslationTracksIgnored: \(nonRootTranslationTracksIgnored)
              directionRetargetIterations: \(directionRetargetIterations)
              bodyBasisMapValid: \(basisMap.valid)
              rootYIgnored: true
              hardAxisSwapsActive: false
            """
        )
    }

    private func logDirectionRetargetRootMotionIfNeeded(
        clip: JockAnimClip,
        sourceDelta: SIMD3<Float>,
        mappedDelta: SIMD3<Float>,
        scaledDelta: SIMD3<Float>,
        heightScale: Float
    ) {
        guard !loggedDirectionRetargetRootMotionClipIDs.contains(clip.clipID) else {
            return
        }

        loggedDirectionRetargetRootMotionClipIDs.insert(clip.clipID)

        print(
            """
            [JockRuntimeDriver] direction retarget root motion
              archetype: \(characterArchetype.rawValue)
              clipID: \(clip.clipID)
              sourceDelta: \(sourceDelta)
              mappedDelta: \(mappedDelta)
              scaledDelta: \(scaledDelta)
              heightScale: \(heightScale)
              rootYIgnored: true
            """
        )
    }

    private func logKneeBendDiagnosticsIfNeeded(
        clip: JockAnimClip,
        time: TimeInterval,
        sourceAnimatedPose: JockWorldPose,
        targetPose: JockWorldPose
    ) {
        let frameIndex = diagnosticFrameIndex(time)

        guard directionRetargetDiagnosticFrames.contains(frameIndex) else {
            return
        }

        let key = "\(characterArchetype.rawValue)|\(clip.clipID)|knee|\(frameIndex)"

        guard !loggedDirectionRetargetKneeDiagnostics.contains(key) else {
            return
        }

        guard let sourceLeftHip = sourceAnimatedPose.joints["LeftUpLeg"]?.worldPosition,
              let sourceLeftKnee = sourceAnimatedPose.joints["LeftLeg"]?.worldPosition,
              let sourceLeftAnkle = sourceAnimatedPose.joints["LeftFoot"]?.worldPosition,
              let sourceRightHip = sourceAnimatedPose.joints["RightUpLeg"]?.worldPosition,
              let sourceRightKnee = sourceAnimatedPose.joints["RightLeg"]?.worldPosition,
              let sourceRightAnkle = sourceAnimatedPose.joints["RightFoot"]?.worldPosition,
              let targetLeftHip = targetPose.joints["LeftUpLeg"]?.worldPosition,
              let targetLeftKnee = targetPose.joints["LeftLeg"]?.worldPosition,
              let targetLeftAnkle = targetPose.joints["LeftFoot"]?.worldPosition,
              let targetRightHip = targetPose.joints["RightUpLeg"]?.worldPosition,
              let targetRightKnee = targetPose.joints["RightLeg"]?.worldPosition,
              let targetRightAnkle = targetPose.joints["RightFoot"]?.worldPosition else {
            return
        }

        loggedDirectionRetargetKneeDiagnostics.insert(key)

        let leftSource = Self.kneeBendAngle(
            hip: sourceLeftHip,
            knee: sourceLeftKnee,
            ankle: sourceLeftAnkle
        )
        let leftTarget = Self.kneeBendAngle(
            hip: targetLeftHip,
            knee: targetLeftKnee,
            ankle: targetLeftAnkle
        )
        let rightSource = Self.kneeBendAngle(
            hip: sourceRightHip,
            knee: sourceRightKnee,
            ankle: sourceRightAnkle
        )
        let rightTarget = Self.kneeBendAngle(
            hip: targetRightHip,
            knee: targetRightKnee,
            ankle: targetRightAnkle
        )

        print(
            """
            [JockRuntimeDriver] knee bend diagnostics
              archetype: \(characterArchetype.rawValue)
              clipID: \(clip.clipID)
              frame: \(frameIndex)
              leftSourceAngleRad: \(leftSource)
              leftTargetAngleRad: \(leftTarget)
              rightSourceAngleRad: \(rightSource)
              rightTargetAngleRad: \(rightTarget)
              targetShouldNotBeStraightLegged: true
            """
        )
    }

    private func logDirectionRetargetEdgeIfNeeded(
        clip: JockAnimClip,
        time: TimeInterval,
        parentName: String,
        childName: String,
        sourceAnimatedDir: SIMD3<Float>,
        desiredTargetDir: SIMD3<Float>,
        currentTargetDirAfter: SIMD3<Float>
    ) {
        let frameIndex = diagnosticFrameIndex(time)

        guard directionRetargetDiagnosticFrames.contains(frameIndex) else {
            return
        }

        let key = "\(characterArchetype.rawValue)|\(clip.clipID)|edge|\(parentName)|\(childName)|\(frameIndex)"

        guard !loggedDirectionRetargetEdgeDiagnostics.contains(key) else {
            return
        }

        loggedDirectionRetargetEdgeDiagnostics.insert(key)

        let dot = max(
            -1,
            min(1, simd_dot(desiredTargetDir, currentTargetDirAfter))
        )
        let angleError = acos(dot)

        print(
            """
            [JockRuntimeDriver] direction retarget edge
              archetype: \(characterArchetype.rawValue)
              clipID: \(clip.clipID)
              frame: \(frameIndex)
              edge: \(parentName)->\(childName)
              sourceAnimatedDir: \(sourceAnimatedDir)
              desiredTargetDir: \(desiredTargetDir)
              currentTargetDirAfter: \(currentTargetDirAfter)
              angleErrorRad: \(angleError)
            """
        )
    }

    private func diagnosticFrameIndex(_ time: TimeInterval) -> Int {
        Int((time * 24.0).rounded())
    }

    private static func buildParentMap(
        jointPaths: [String]
    ) -> [String: String] {
        var parentByJoint: [String: String] = [:]

        for path in jointPaths {
            let parts = path.split(separator: "/").map(String.init)
            guard let leaf = parts.last,
                  parts.count > 1 else {
                continue
            }

            parentByJoint[leaf] = parts[parts.count - 2]
        }

        return parentByJoint
    }

    private static func identityTransform() -> Transform {
        Transform(
            scale: SIMD3<Float>(repeating: 1),
            rotation: identityQuaternion(),
            translation: .zero
        )
    }

    private static func identityQuaternion() -> simd_quatf {
        simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    }

    private static func normalizeSafe(
        _ vector: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let length = simd_length(vector)

        guard length > 0.000001 else {
            return fallback
        }

        return vector / length
    }

    private static func rotationBetween(
        from source: SIMD3<Float>,
        to target: SIMD3<Float>
    ) -> simd_quatf {
        let from = normalizeSafe(
            source,
            fallback: SIMD3<Float>(0, 1, 0)
        )
        let to = normalizeSafe(
            target,
            fallback: from
        )
        let dot = max(-1, min(1, simd_dot(from, to)))

        if dot > 0.9999 {
            return identityQuaternion()
        }

        if dot < -0.9999 {
            let candidate = abs(from.x) < 0.9
                ? SIMD3<Float>(1, 0, 0)
                : SIMD3<Float>(0, 0, 1)
            let axis = normalizeSafe(
                simd_cross(from, candidate),
                fallback: SIMD3<Float>(0, 1, 0)
            )

            return simd_quatf(angle: .pi, axis: axis)
        }

        return simd_quatf(from: from, to: to)
    }

    private static func rotationMatrix(
        from matrix: simd_float4x4
    ) -> simd_float3x3 {
        let x = normalizeSafe(
            SIMD3<Float>(
                matrix.columns.0.x,
                matrix.columns.0.y,
                matrix.columns.0.z
            ),
            fallback: SIMD3<Float>(1, 0, 0)
        )
        let y = normalizeSafe(
            SIMD3<Float>(
                matrix.columns.1.x,
                matrix.columns.1.y,
                matrix.columns.1.z
            ),
            fallback: SIMD3<Float>(0, 1, 0)
        )
        let z = normalizeSafe(
            SIMD3<Float>(
                matrix.columns.2.x,
                matrix.columns.2.y,
                matrix.columns.2.z
            ),
            fallback: SIMD3<Float>(0, 0, 1)
        )

        return simd_float3x3(x, y, z)
    }

    private static func globalJointTransform(
        from matrix: simd_float4x4
    ) -> GlobalJointTransform {
        let x = SIMD3<Float>(
            matrix.columns.0.x,
            matrix.columns.0.y,
            matrix.columns.0.z
        )
        let y = SIMD3<Float>(
            matrix.columns.1.x,
            matrix.columns.1.y,
            matrix.columns.1.z
        )
        let z = SIMD3<Float>(
            matrix.columns.2.x,
            matrix.columns.2.y,
            matrix.columns.2.z
        )

        return GlobalJointTransform(
            translation: SIMD3<Float>(
                matrix.columns.3.x,
                matrix.columns.3.y,
                matrix.columns.3.z
            ),
            rotation: simd_normalize(
                simd_quatf(rotationMatrix(from: matrix))
            ),
            scale: SIMD3<Float>(
                simd_length(x),
                simd_length(y),
                simd_length(z)
            )
        )
    }

    private static func matrix(
        from transform: GlobalJointTransform
    ) -> simd_float4x4 {
        Transform(
            scale: transform.scale,
            rotation: transform.rotation,
            translation: transform.translation
        ).matrix
    }

    private static func kneeBendAngle(
        hip: SIMD3<Float>,
        knee: SIMD3<Float>,
        ankle: SIMD3<Float>
    ) -> Float {
        let upper = normalizeSafe(
            hip - knee,
            fallback: SIMD3<Float>(0, 1, 0)
        )
        let lower = normalizeSafe(
            ankle - knee,
            fallback: SIMD3<Float>(0, -1, 0)
        )
        let dot = max(-1, min(1, simd_dot(upper, lower)))

        return acos(dot)
    }

    private func logPreserveRotationBasisDiagnosticsIfNeeded(
        clip: JockAnimClip,
        jointName: String,
        targetBase: Transform,
        sampledRotation: simd_quatf,
        referenceRotation: simd_quatf,
        parentSpaceDelta: simd_quatf,
        finalRotation: simd_quatf
    ) {
        guard poseApplicationPolicy == .preserveTargetSkeleton else {
            return
        }

        guard preserveRotationDiagnosticJoints.contains(jointName) else {
            return
        }

        let key = "\(characterArchetype.rawValue)|\(clip.clipID)|\(jointName)"

        guard !loggedPreserveRotationBasisDiagnostics.contains(key) else {
            return
        }

        loggedPreserveRotationBasisDiagnostics.insert(key)

        print(
            """
            [JockRuntimeDriver] preserve-target rotation basis diagnostic
              archetype: \(characterArchetype.rawValue)
              clip: \(clip.clipID)
              joint: \(jointName)
              policy: \(poseApplicationPolicy.rawValue)
              usedBasisConvertedRotation: true

              sourceReferenceRotation_xyzw: \(referenceRotation.vector)
              sampledRotation_xyzw: \(sampledRotation.vector)
              targetBaseRotation_xyzw: \(targetBase.rotation.vector)
              parentSpaceDelta_xyzw: \(parentSpaceDelta.vector)
              finalRotation_xyzw: \(finalRotation.vector)

              formula: final = (sampled * inverse(sourceReference)) * targetBase
            """
        )
    }

    private func logPreserveTargetSkeletonDiagnosticsIfNeeded(
        clip: JockAnimClip,
        preparedTracks: [JockPreparedTrack]
    ) {
        guard !loggedPreservePolicyClipIDs.contains(clip.clipID) else {
            return
        }

        loggedPreservePolicyClipIDs.insert(clip.clipID)

        let absoluteRotationTracksApplied = preparedTracks.filter { track in
            track.channel == "rotation_quat_wxyz_absolute"
        }.count

        let rootTranslationTracksApplied = preparedTracks.filter { track in
            track.channel == "translation_xyz_absolute" &&
                isRootTranslationJoint(track.joint)
        }.count

        let nonRootTranslationTracksIgnored = preparedTracks.filter { track in
            track.channel == "translation_xyz_absolute" &&
                !isRootTranslationJoint(track.joint)
        }.count

        let absoluteScaleTracksIgnored = preparedTracks.filter { track in
            track.channel == "scale_xyz_absolute"
        }.count

        let additiveRotationTracksApplied = preparedTracks.filter { track in
            track.channel == "rotation_quat_wxyz_additive" ||
                track.channel == "rotation_euler_xyz_degrees_additive"
        }.count

        let rootAdditiveTranslationTracksApplied = preparedTracks.filter { track in
            track.channel == "translation_xyz_additive" &&
                isRootTranslationJoint(track.joint)
        }.count

        let nonRootAdditiveTranslationTracksIgnored = preparedTracks.filter { track in
            track.channel == "translation_xyz_additive" &&
                !isRootTranslationJoint(track.joint)
        }.count

        let mappedRuntimeIndices = Set(preparedTracks.map(\.runtimeIndex))
        let targetOnlyJointNames = jointNames.enumerated()
            .filter { index, _ in !mappedRuntimeIndices.contains(index) }
            .map(\.element)

        print(
            """
            [JockRuntimeDriver] preserve target skeleton sampling
              characterArchetype: \(characterArchetype.rawValue)
              clipID: \(clip.clipID)
              poseApplicationPolicy: \(poseApplicationPolicy.rawValue)
              runtimeJointCount: \(jointNames.count)
              animationTrackJoints: \(Set(preparedTracks.map(\.joint)).count)
              matchedJointCount: \(matchedJointCount)
              matchedRuntimeIndices: \(mappedRuntimeIndices.count)
              absoluteRotationTracksApplied: \(absoluteRotationTracksApplied)
              rootTranslationTracksApplied: \(rootTranslationTracksApplied)
              nonRootTranslationTracksIgnored: \(nonRootTranslationTracksIgnored)
              absoluteScaleTracksIgnored: \(absoluteScaleTracksIgnored)
              additiveRotationTracksApplied: \(additiveRotationTracksApplied)
              rootAdditiveTranslationTracksApplied: \(rootAdditiveTranslationTracksApplied)
              nonRootAdditiveTranslationTracksIgnored: \(nonRootAdditiveTranslationTracksIgnored)
              basisConvertedAbsoluteRotations: true
              hardAxisSwapsActive: \(!preserveTargetJointRotationCorrections.isEmpty)
              targetJointsWithoutAnimationTracks: \(targetOnlyJointNames.count)
              targetJointsWithoutAnimationSample: \(targetOnlyJointNames.prefix(20).joined(separator: ", "))
            """
        )
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
        guard activeLocomotionPolicy == .useClipLocomotion else {
            return
        }

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
