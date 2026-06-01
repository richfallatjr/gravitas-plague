import Foundation
import RealityKit
import simd

@MainActor
final class BakedInfectedController {
    enum ControllerError: LocalizedError {
        case missingAsset(fileName: String)
        case failedToFindAnimation(fileName: String)
        case missingLoadedSource(ClipID)

        var errorDescription: String? {
            switch self {
            case .missingAsset(let fileName):
                return "Missing required USDZ asset: \(fileName)"
            case .failedToFindAnimation(let fileName):
                return "No animation was found in required USDZ asset: \(fileName)"
            case .missingLoadedSource(let clipID):
                return "No loaded source entity exists for clip: \(clipID)"
            }
        }
    }

    let rootEntity = Entity()

    private let configuration: PhaseOneConfiguration
    private let clips: [BakedAnimationClip]
    private let sequence: [PhaseOneSequenceStep]

    private var clipsByID: [ClipID: BakedAnimationClip] = [:]
    private var loadedSources: [ClipID: Entity] = [:]

    private var activeStep: PhaseOneSequenceStep?
    private var activeClip: BakedAnimationClip?

    private var activeClipID: ClipID?
    private var activeClipMountEntity: Entity?
    private var activeClipEntity: Entity?
    private var activeAnimationController: AnimationPlaybackController?

    private var hasLoadedClips = false
    private var isRunning = false
    private var sequenceIndex = 0

    private var rootYawRadians: Float = 0
    private var farPoint = SIMD3<Float>(0, -1.45, -3.05)

    init(
        configuration: PhaseOneConfiguration,
        clips: [BakedAnimationClip] = BakedAnimationClip.phaseOneClips,
        sequence: [PhaseOneSequenceStep] = PhaseOneSequenceStep.phaseOneLoop
    ) {
        self.configuration = configuration
        self.clips = clips
        self.sequence = sequence

        for clip in clips {
            clipsByID[clip.id] = clip
        }

        rootEntity.name = "GravitasPlague_InfectedRoot"
        rootEntity.isEnabled = true
    }

    func loadClips() async throws {
        guard !hasLoadedClips else { return }

        var loadedSourcesByAssetKey: [String: Entity] = [:]

        for clip in clips {
            if let existingSource = loadedSourcesByAssetKey[clip.assetKey] {
                loadedSources[clip.id] = existingSource
                continue
            }

            guard let url = Bundle.main.url(
                forResource: clip.fileBaseName,
                withExtension: clip.fileExtension
            ) else {
                throw ControllerError.missingAsset(fileName: clip.fullFileName)
            }

            let sourceEntity = try await Entity(
                contentsOf: url,
                withName: clip.fileBaseName
            )

            guard firstAnimationEntityAndResource(in: sourceEntity) != nil else {
                throw ControllerError.failedToFindAnimation(fileName: clip.fullFileName)
            }

            sourceEntity.name = "Source_\(clip.fileBaseName)"

            loadedSourcesByAssetKey[clip.assetKey] = sourceEntity
            loadedSources[clip.id] = sourceEntity
        }

        hasLoadedClips = true
    }

    func configureSpawn(
        using spawnPose: PhaseOneSpawnPose,
        floorY: Float
    ) {
        let headForward = PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(spawnPose.headForward.x, 0, spawnPose.headForward.z),
            fallback: SIMD3<Float>(0, 0, -1)
        )

        farPoint = SIMD3<Float>(
            spawnPose.headPosition.x + headForward.x * configuration.farDistance,
            floorY,
            spawnPose.headPosition.z + headForward.z * configuration.farDistance
        )

        rootYawRadians = PhaseOneMath.yawRadiansForNegativeZForward(
            worldForward: headForward
        )

        rootEntity.position = farPoint
        applyRootTransform()
    }

    func prepareIdleAtSpawn() {
        guard hasLoadedClips else { return }

        isRunning = false
        sequenceIndex = 0

        rootEntity.isEnabled = true
        rootEntity.position = farPoint
        applyRootTransform()

        playSequenceStep(
            PhaseOneSequenceStep(
                clipID: .idle,
                repeatCount: 1,
                translatesRootWhilePlaying: false,
                commitRightTurnYawOnCompletion: false
            )
        )
    }

    func startLoop() {
        guard hasLoadedClips else { return }

        rootEntity.isEnabled = true
        rootEntity.position = farPoint
        applyRootTransform()

        isRunning = true
        sequenceIndex = 0

        playCurrentSequenceStep()
    }

    func resetLoopToIdleFar() {
        guard hasLoadedClips else { return }

        rootEntity.isEnabled = true
        rootEntity.position = farPoint
        applyRootTransform()

        isRunning = true
        sequenceIndex = 0

        playCurrentSequenceStep()
    }

    func stopLoopAndHide() {
        isRunning = false
        sequenceIndex = 0

        activeAnimationController?.stop()
        activeAnimationController = nil

        activeClipMountEntity?.removeFromParent()
        activeClipMountEntity = nil

        activeClipEntity = nil
        activeClipID = nil
        activeStep = nil
        activeClip = nil

        rootEntity.isEnabled = false
    }

    func update(
        deltaTime: Float,
        currentHeadPosition: SIMD3<Float>?
    ) {
        guard hasLoadedClips else { return }
        _ = currentHeadPosition

        let clampedDelta = max(0, min(deltaTime, 0.1))

        if isRunning,
           let activeStep,
           activeStep.translatesRootWhilePlaying {
            translateRootForward(deltaTime: clampedDelta)
        }

        guard isRunning else { return }

        if activeAnimationHasCompleted() {
            completeActiveStepAndAdvance()
        }
    }

    private func playCurrentSequenceStep() {
        guard !sequence.isEmpty else { return }

        let safeIndex = sequenceIndex % sequence.count
        playSequenceStep(sequence[safeIndex])
    }

    private func playSequenceStep(_ step: PhaseOneSequenceStep) {
        guard hasLoadedClips else { return }

        guard step.repeatCount > 0 else {
            assertionFailure("Invalid repeatCount for \(step.clipID): \(step.repeatCount)")
            return
        }

        activeAnimationController?.stop()
        activeAnimationController = nil

        activeClipMountEntity?.removeFromParent()
        activeClipMountEntity = nil

        activeClipEntity = nil
        activeClipID = nil
        activeStep = nil
        activeClip = nil

        guard let sourceEntity = loadedSources[step.clipID] else {
            assertionFailure(ControllerError.missingLoadedSource(step.clipID).localizedDescription)
            return
        }

        guard let clip = clipsByID[step.clipID] else {
            assertionFailure("Missing clip metadata for \(step.clipID)")
            return
        }

        let clipMount = Entity()
        clipMount.name = "ActiveClipMount_\(clip.fileBaseName)_\(step.clipID)"
        clipMount.position = .zero
        clipMount.scale = SIMD3<Float>(1, 1, 1)
        clipMount.orientation = configuration.visualCorrectionOrientation

        let clone = sourceEntity.clone(recursive: true)
        clone.name = "Active_\(clip.fileBaseName)_\(step.clipID)"

        // Preserve the imported USDZ transform. Do not reset clone position/orientation/scale.
        clipMount.addChild(clone)
        rootEntity.addChild(clipMount)

        if configuration.autoAlignVisualBottomToGround {
            snapVisualBottomToRootGround(clipMount)
        }

        guard let animationTarget = firstAnimationEntityAndResource(in: clone) else {
            assertionFailure("No playable animation found in clone for \(clip.fullFileName)")
            clipMount.removeFromParent()
            return
        }

        let baseAnimationResource = animationTarget.resource
        let playbackResource: AnimationResource

        if step.repeatCount == 1 {
            playbackResource = baseAnimationResource
        } else {
            playbackResource = baseAnimationResource.repeat(count: step.repeatCount)
        }

        let controller = animationTarget.entity.playAnimation(
            playbackResource,
            transitionDuration: configuration.clipTransitionDuration,
            startsPaused: false
        )

        activeAnimationController = controller
        activeClipMountEntity = clipMount
        activeClipEntity = clone
        activeClipID = step.clipID
        activeStep = step
        activeClip = clip

        if configuration.logClipDurations {
            print(
                """
                [Gravitas] Playing sequence step
                  clipID: \(step.clipID)
                  file: \(clip.fullFileName)
                  repeatCount: \(step.repeatCount)
                  translatesRootWhilePlaying: \(step.translatesRootWhilePlaying)
                  commitRightTurnYawOnCompletion: \(step.commitRightTurnYawOnCompletion)
                  controllerDuration: \(String(format: "%.3f", controller.duration))
                  transitionDuration: \(String(format: "%.3f", configuration.clipTransitionDuration))
                """
            )
        }
    }

    private func activeAnimationHasCompleted() -> Bool {
        guard let controller = activeAnimationController else {
            return false
        }

        let duration = controller.duration

        guard duration.isFinite, duration > 0.001 else {
            return false
        }

        let currentTime = controller.time
        let threshold = max(0, duration - configuration.animationCompletionTolerance)

        return currentTime >= threshold
    }

    private func completeActiveStepAndAdvance() {
        guard let step = activeStep else { return }

        if step.commitRightTurnYawOnCompletion {
            commitRightTurnYaw()
        }

        sequenceIndex = (sequenceIndex + 1) % sequence.count
        playCurrentSequenceStep()
    }

    private func commitRightTurnYaw() {
        rootYawRadians -= Float.pi / 2.0
        rootYawRadians = PhaseOneMath.normalizedAngleRadians(rootYawRadians)
        applyRootTransform()
    }

    private func translateRootForward(deltaTime: Float) {
        let localForward = SIMD3<Float>(0, 0, -1)
        let worldForward = rootEntity.orientation.act(localForward)

        let horizontalForward = PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(worldForward.x, 0, worldForward.z),
            fallback: SIMD3<Float>(0, 0, -1)
        )

        rootEntity.position += horizontalForward * configuration.walkSpeedMetersPerSecond * deltaTime
    }

    private func applyRootTransform() {
        rootEntity.scale = configuration.rootScale

        let yaw = rootYawRadians + configuration.rootYawOffsetRadians

        rootEntity.orientation = simd_quatf(
            angle: yaw,
            axis: SIMD3<Float>(0, 1, 0)
        )
    }

    private func snapVisualBottomToRootGround(_ clipMount: Entity) {
        let bounds = clipMount.visualBounds(
            recursive: true,
            relativeTo: rootEntity,
            excludeInactive: false
        )

        let bottomY = bounds.min.y

        guard bottomY.isFinite else {
            return
        }

        clipMount.position.y -= bottomY
    }

    private func firstAnimationEntityAndResource(
        in entity: Entity
    ) -> (entity: Entity, resource: AnimationResource)? {
        if let firstAnimation = entity.availableAnimations.first {
            return (entity, firstAnimation)
        }

        for child in entity.children {
            if let found = firstAnimationEntityAndResource(in: child) {
                return found
            }
        }

        return nil
    }
}
