import Foundation
import RealityKit
import simd

@MainActor
final class BakedInfectedController {
    enum PhaseOneState: Equatable {
        case loading
        case stopped
        case idleFar
        case turningTowardUserFirst90
        case turningTowardUserSecond90
        case walkingTowardUser
        case idleNear
        case turningAwayFirst90
        case turningAwaySecond90
        case walkingAway
    }

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
    private var clipsByID: [ClipID: BakedAnimationClip] = [:]
    private var loadedSources: [ClipID: Entity] = [:]

    private var activeClipID: ClipID?
    private var activeClip: BakedAnimationClip?
    private var activeClipDuration: TimeInterval?
    private var activeClipMountEntity: Entity?
    private var activeClipEntity: Entity?
    private var activeAnimationController: AnimationPlaybackController?

    private(set) var state: PhaseOneState = .loading
    private var stateElapsed: TimeInterval = 0
    private var isRunning = false
    private var hasLoadedClips = false

    private var rootYawRadians: Float = 0
    private var farPoint = SIMD3<Float>(0, 0, -3.05)
    private var nearPoint = SIMD3<Float>(0, 0, -1.55)

    init(
        configuration: PhaseOneConfiguration,
        clips: [BakedAnimationClip] = BakedAnimationClip.phaseOneClips
    ) {
        self.configuration = configuration
        self.clips = clips

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
        state = .stopped
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

        nearPoint = SIMD3<Float>(
            spawnPose.headPosition.x + headForward.x * configuration.nearDistance,
            floorY,
            spawnPose.headPosition.z + headForward.z * configuration.nearDistance
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
        rootEntity.isEnabled = true
        rootEntity.position = farPoint
        applyRootTransform()
        switchToClip(.idle)

        state = .idleFar
        stateElapsed = 0
    }

    func startLoop() {
        guard hasLoadedClips else { return }

        rootEntity.isEnabled = true
        rootEntity.position = farPoint
        applyRootTransform()

        isRunning = true
        transition(to: .idleFar)
    }

    func resetLoopToIdleFar() {
        guard hasLoadedClips else { return }

        rootEntity.isEnabled = true
        rootEntity.position = farPoint
        applyRootTransform()

        isRunning = true
        transition(to: .idleFar)
    }

    func stopLoopAndHide() {
        isRunning = false
        activeAnimationController?.stop()
        activeAnimationController = nil

        activeClipMountEntity?.removeFromParent()
        activeClipMountEntity = nil
        activeClipEntity = nil
        activeClipID = nil
        activeClip = nil
        activeClipDuration = nil

        rootEntity.isEnabled = false
        state = .stopped
        stateElapsed = 0
    }

    func update(
        deltaTime: Float,
        currentHeadPosition: SIMD3<Float>?
    ) {
        guard isRunning, hasLoadedClips else { return }

        let clampedDelta = max(0, min(deltaTime, 0.1))
        stateElapsed += TimeInterval(clampedDelta)

        if enforceSafetyIfNeeded(currentHeadPosition: currentHeadPosition) {
            return
        }

        switch state {
        case .loading, .stopped:
            return

        case .idleFar:
            if stateElapsed >= configuration.idleFarDuration {
                transition(to: .turningTowardUserFirst90)
            }

        case .turningTowardUserFirst90:
            completeRightTurnIfNeeded(nextState: .turningTowardUserSecond90)

        case .turningTowardUserSecond90:
            completeRightTurnIfNeeded(nextState: .walkingTowardUser)

        case .walkingTowardUser:
            if moveRootToward(target: nearPoint, deltaTime: clampedDelta) {
                transition(to: .idleNear)
            }

        case .idleNear:
            if stateElapsed >= configuration.idleNearDuration {
                transition(to: .turningAwayFirst90)
            }

        case .turningAwayFirst90:
            completeRightTurnIfNeeded(nextState: .turningAwaySecond90)

        case .turningAwaySecond90:
            completeRightTurnIfNeeded(nextState: .walkingAway)

        case .walkingAway:
            if moveRootToward(target: farPoint, deltaTime: clampedDelta) {
                transition(to: .idleFar)
            }
        }
    }

    private func transition(to newState: PhaseOneState) {
        state = newState
        stateElapsed = 0

        switch newState {
        case .loading, .stopped:
            break

        case .idleFar, .idleNear:
            switchToClip(.idle)

        case .turningTowardUserFirst90,
             .turningAwayFirst90:
            switchToClip(.turnRight01)

        case .turningTowardUserSecond90,
             .turningAwaySecond90:
            switchToClip(.turnRight02)

        case .walkingTowardUser, .walkingAway:
            switchToClip(.unstableWalk)
        }
    }

    private func completeRightTurnIfNeeded(nextState: PhaseOneState) {
        guard activeOneShotClipHasReachedEnd() else { return }

        commitRightTurnYaw()
        transition(to: nextState)
    }

    private func activeOneShotClipHasReachedEnd() -> Bool {
        guard let activeClip else {
            return false
        }

        guard activeClip.looping == false else {
            return false
        }

        let duration = resolvedActiveOneShotDuration(for: activeClip)

        let playbackTime = activeAnimationController?.time ?? stateElapsed
        let safePlaybackTime = max(playbackTime, stateElapsed)

        return safePlaybackTime >= duration - configuration.oneShotCompletionTolerance
    }

    private func resolvedActiveOneShotDuration(
        for activeClip: BakedAnimationClip
    ) -> TimeInterval {
        if let activeClipDuration,
           activeClipDuration.isFinite,
           activeClipDuration > 0.05 {
            return activeClipDuration
        }

        if let fallback = activeClip.fallbackDuration,
           fallback.isFinite,
           fallback > 0.05 {
            return fallback + activeClip.completionHold
        }

        return configuration.defaultOneShotFallbackDuration + activeClip.completionHold
    }

    private func commitRightTurnYaw() {
        rootYawRadians -= Float.pi / 2.0
        rootYawRadians = PhaseOneMath.normalizedAngleRadians(rootYawRadians)
        applyRootTransform()
    }

    private func moveRootToward(
        target: SIMD3<Float>,
        deltaTime: Float
    ) -> Bool {
        let current = rootEntity.position
        let toTarget = target - current
        let distance = simd_length(toTarget)

        if distance <= configuration.walkStopEpsilon {
            rootEntity.position = target
            return true
        }

        let step = configuration.walkSpeedMetersPerSecond * deltaTime

        if step >= distance {
            rootEntity.position = target
            return true
        }

        let direction = simd_normalize(toTarget)
        rootEntity.position = current + direction * step
        return false
    }

    private func enforceSafetyIfNeeded(
        currentHeadPosition: SIMD3<Float>?
    ) -> Bool {
        guard let currentHeadPosition else { return false }
        guard state == .walkingTowardUser else { return false }

        let distanceToUser = PhaseOneMath.horizontalDistance(
            from: rootEntity.position,
            to: currentHeadPosition
        )

        guard distanceToUser <= configuration.nearDistance else {
            return false
        }

        rootEntity.position = nearPoint
        transition(to: .idleNear)
        return true
    }

    private func applyRootTransform() {
        rootEntity.scale = configuration.rootScale

        let yaw = rootYawRadians + configuration.rootYawOffsetRadians
        rootEntity.orientation = simd_quatf(
            angle: yaw,
            axis: SIMD3<Float>(0, 1, 0)
        )
    }

    private func switchToClip(_ clipID: ClipID) {
        guard hasLoadedClips else { return }

        activeAnimationController?.stop()
        activeAnimationController = nil

        activeClipMountEntity?.removeFromParent()
        activeClipMountEntity = nil
        activeClipEntity = nil
        activeClipID = nil
        activeClip = nil
        activeClipDuration = nil

        guard let sourceEntity = loadedSources[clipID] else {
            assertionFailure(ControllerError.missingLoadedSource(clipID).localizedDescription)
            return
        }

        guard let clip = clipsByID[clipID] else {
            assertionFailure("Missing clip metadata for \(clipID)")
            return
        }

        let clipMount = Entity()
        clipMount.name = "ActiveClipMount_\(clip.fileBaseName)_\(clipID)"
        clipMount.position = .zero
        clipMount.scale = SIMD3<Float>(1, 1, 1)
        clipMount.orientation = configuration.visualCorrectionOrientation

        let clone = sourceEntity.clone(recursive: true)
        clone.name = "Active_\(clip.fileBaseName)_\(clipID)"

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

        let animationResource: AnimationResource

        if clip.looping {
            animationResource = animationTarget.resource.repeat(
                duration: configuration.loopedAnimationRepeatDuration
            )
        } else {
            animationResource = animationTarget.resource
        }

        let controller = animationTarget.entity.playAnimation(
            animationResource,
            transitionDuration: configuration.clipTransitionDuration,
            startsPaused: false
        )

        activeAnimationController = controller
        activeClipMountEntity = clipMount
        activeClipEntity = clone
        activeClipID = clipID
        activeClip = clip

        if clip.looping {
            activeClipDuration = nil
        } else {
            let reportedDuration = controller.duration

            if reportedDuration.isFinite, reportedDuration > 0.05 {
                activeClipDuration = reportedDuration + clip.completionHold
            } else if let fallback = clip.fallbackDuration {
                activeClipDuration = fallback + clip.completionHold
            } else {
                activeClipDuration = configuration.defaultOneShotFallbackDuration + clip.completionHold
            }
        }

        if configuration.logClipDurations {
            let durationText: String

            if let activeClipDuration {
                durationText = String(format: "%.3f", activeClipDuration)
            } else {
                durationText = "looping"
            }

            print(
                """
                [Gravitas] Playing clip:
                  id: \(clipID)
                  file: \(clip.fullFileName)
                  looping: \(clip.looping)
                  resolvedDuration: \(durationText)
                  reportedControllerDuration: \(String(format: "%.3f", controller.duration))
                """
            )
        }
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
