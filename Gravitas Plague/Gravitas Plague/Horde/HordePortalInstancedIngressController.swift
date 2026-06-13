import Foundation
import QuartzCore
import RealityKit
import simd

enum HordePortalIngressDepth {
    static let feetToMeters: Float = 0.3048

    static let minFeet: Float = 5.0
    static let maxFeet: Float = 10.0

    static let minMeters: Float = minFeet * feetToMeters
    static let maxMeters: Float = maxFeet * feetToMeters

    static func randomMeters() -> Float {
        Float.random(
            in: minMeters...maxMeters
        )
    }
}

@MainActor
final class HordePortalRenderInstance {
    let id = UUID()
    let sourceEnemyID: UUID
    let rootEntity: Entity

    private weak var source: JockRetargetTestController?
    private weak var sourceSkinnedModel: ModelEntity?
    private weak var instanceSkinnedModel: ModelEntity?
    private var lastSyncLogTime: CFTimeInterval = 0

    init(
        source: JockRetargetTestController,
        portalWorldRoot: Entity
    ) throws {
        self.source = source
        self.sourceEnemyID = source.hordeBenchmarkID

        let instance = source.rootEntity.clone(
            recursive: true
        )
        instance.name = "PortalRenderInstance_\(sourceEnemyID.uuidString.prefix(8))"
        self.rootEntity = instance

        Self.stripGameplayComponentsRecursively(instance)

        self.sourceSkinnedModel = source.skinnedModelEntityForPortalInstance()
        self.instanceSkinnedModel = Self.firstSkinnedModelEntity(
            in: instance
        )

        portalWorldRoot.addChild(instance)
        rootEntity.isEnabled = true

        print(
            """
            [HordePortalInstance] created
              sourceEnemyID: \(sourceEnemyID)
              instanceID: \(id)
              sourceHasSkinnedModel: \(sourceSkinnedModel != nil)
              instanceHasSkinnedModel: \(instanceSkinnedModel != nil)
              parent: portalWorldRoot
              resourceSharingIntent: true
              secondController: false
              secondAnimationClock: false
              enabledFromStart: true
              noFade: true
            """
        )
    }

    func syncFromSource(
        worldPosition: SIMD3<Float>,
        worldOrientation: simd_quatf,
        portalWorldRoot: Entity
    ) {
        guard let source else {
            return
        }

        Self.copyChildTransforms(
            from: source.rootEntity,
            to: rootEntity,
            includeRoot: false
        )

        if let sourceSkinnedModel,
           let instanceSkinnedModel {
            instanceSkinnedModel.jointTransforms = sourceSkinnedModel.jointTransforms
        }

        let localPosition = portalWorldRoot.convert(
            position: worldPosition,
            from: nil
        )

        rootEntity.position = localPosition

        let portalWorldOrientation = portalWorldRoot.orientation(
            relativeTo: nil
        )

        rootEntity.orientation =
            simd_inverse(portalWorldOrientation) * worldOrientation

        let now = CACurrentMediaTime()
        if now - lastSyncLogTime >= 1.0 {
            lastSyncLogTime = now

            print(
                """
                [HordePortalInstance] synced from source
                  sourceEnemyID: \(sourceEnemyID)
                  instanceID: \(id)
                  worldPosition: \(worldPosition)
                  noIndependentAnimation: true
                """
            )
        }
    }

    func removeAfterExit() {
        rootEntity.removeFromParent()

        print(
            """
            [HordePortalInstance] removed after exit
              sourceEnemyID: \(sourceEnemyID)
              instanceID: \(id)
            """
        )
    }

    private static func stripGameplayComponentsRecursively(
        _ entity: Entity
    ) {
        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(CollisionComponent.self)

        for child in entity.children {
            stripGameplayComponentsRecursively(child)
        }
    }

    private static func firstSkinnedModelEntity(
        in entity: Entity
    ) -> ModelEntity? {
        if let modelEntity = entity as? ModelEntity,
           !modelEntity.jointNames.isEmpty {
            return modelEntity
        }

        for child in entity.children {
            if let found = firstSkinnedModelEntity(
                in: child
            ) {
                return found
            }
        }

        return nil
    }

    private static func copyChildTransforms(
        from source: Entity,
        to instance: Entity,
        includeRoot: Bool
    ) {
        if includeRoot {
            instance.transform = source.transform
        }

        let pairCount = min(
            source.children.count,
            instance.children.count
        )

        for index in 0..<pairCount {
            let sourceChild = source.children[index]
            let instanceChild = instance.children[index]
            instanceChild.transform = sourceChild.transform

            copyChildTransforms(
                from: sourceChild,
                to: instanceChild,
                includeRoot: false
            )
        }
    }
}

@MainActor
final class HordePortalInstancedIngressController {
    enum Phase: String {
        case walkingParallelInsidePortal
        case turningTowardExit
        case crossingAperture
        case realWorldFollowing
        case failed
    }

    let enemyID: UUID
    let portalID: UUID
    let side: HordePortalEntranceSide

    private let enemy: JockRetargetTestController
    private let portal: HordePortal
    private var portalInstance: HordePortalRenderInstance?
    private weak var sceneRoot: Entity?

    private(set) var phase: Phase = .walkingParallelInsidePortal

    private var portalLocalPosition: SIMD3<Float>
    private var worldPosition: SIMD3<Float>
    private var worldOrientation: simd_quatf

    private let floorY: Float
    private let depthMeters: Float
    private let parallelSpeed: Float
    private let crossingSpeed: Float

    private var turnHasStarted = false
    private var turnHasFinished = false
    private var turnClipID: String?
    private var turnTimer: Float = 0
    private var turnDuration: Float = 1.0
    private var turnStartYaw = simd_quatf(
        angle: 0,
        axis: SIMD3<Float>(0, 1, 0)
    )
    private var turnEndYaw = simd_quatf(
        angle: 0,
        axis: SIMD3<Float>(0, 1, 0)
    )

    private let removeInstanceZ: Float = 0.45

    init(
        enemy: JockRetargetTestController,
        portal: HordePortal,
        sceneRoot: Entity,
        side: HordePortalEntranceSide
    ) throws {
        self.enemy = enemy
        self.portal = portal
        self.sceneRoot = sceneRoot
        self.side = side
        self.enemyID = enemy.hordeBenchmarkID
        self.portalID = portal.id
        self.floorY = portal.resolvedFloorWorldY ?? portal.placement.floorWorldY ?? 0

        let depth = HordePortalIngressDepth.randomMeters()
        self.depthMeters = depth
        self.parallelSpeed = Float.random(in: 0.45...0.78)
        self.crossingSpeed = Float.random(in: 0.72...1.05)

        let startX = side.startLocalXSign * portal.placement.width * 0.72
        let startY = portal.localRootYForEnemy(
            enemy: enemy
        )

        self.portalLocalPosition = SIMD3<Float>(
            startX,
            startY,
            -depth
        )

        let rawWorld = portal.root.convert(
            position: portalLocalPosition,
            to: nil
        )

        self.worldPosition = SIMD3<Float>(
            rawWorld.x,
            enemy.rootYForFloorY(floorY),
            rawWorld.z
        )

        self.worldOrientation = Self.yawOnlyOrientation(
            portalRoot: portal.root,
            portalLocalDirection: SIMD3<Float>(
                side.walkDirectionLocalX,
                0,
                0
            )
        )

        try setup()
    }

    func update(
        deltaTime: Float,
        playerWorldPosition: SIMD3<Float>
    ) {
        switch phase {
        case .realWorldFollowing, .failed:
            return

        case .walkingParallelInsidePortal,
             .turningTowardExit,
             .crossingAperture:
            break
        }

        assertBothVisualsAlwaysOn(
            context: "pre_\(phase.rawValue)"
        )

        switch phase {
        case .walkingParallelInsidePortal:
            updateParallel(
                deltaTime: deltaTime
            )

        case .turningTowardExit:
            updateTurn(
                deltaTime: deltaTime
            )

        case .crossingAperture:
            updateCrossing(
                deltaTime: deltaTime,
                playerWorldPosition: playerWorldPosition
            )

        case .realWorldFollowing, .failed:
            return
        }

        switch phase {
        case .realWorldFollowing, .failed:
            return

        case .walkingParallelInsidePortal,
             .turningTowardExit,
             .crossingAperture:
            break
        }

        enemy.forceAnimationTickIfAvailable(
            deltaTime: deltaTime
        )
        syncInstanceFromSource()

        assertBothVisualsAlwaysOn(
            context: "post_\(phase.rawValue)"
        )
    }
}

private extension HordePortalInstancedIngressController {
    func setup() throws {
        guard let sceneRoot else {
            phase = .failed
            throw NSError(
                domain: "HordePortalIngress",
                code: 500,
                userInfo: [
                    NSLocalizedDescriptionKey: "Missing scene root during instanced portal ingress setup."
                ]
            )
        }

        if enemy.rootEntity.parent !== sceneRoot {
            enemy.rootEntity.removeFromParent()
            sceneRoot.addChild(enemy.rootEntity)
        }

        enemy.prepareForHordePortalIngress()
        enemy.rootEntity.isEnabled = true
        enemy.setCombatEnabled(false)
        enemy.setRootMotionEnabled(false)
        enemy.setExternalMotionDriven(true)

        applyAuthoritativeWorldPose(
            localDirection: SIMD3<Float>(
                side.walkDirectionLocalX,
                0,
                0
            )
        )

        enemy.forceOneAnimationTickIfAvailable()

        portalInstance = try HordePortalRenderInstance(
            source: enemy,
            portalWorldRoot: portal.portalWorldRoot
        )
        portalInstance?.rootEntity.isEnabled = true

        syncInstanceFromSource()

        assertBothVisualsAlwaysOn(
            context: "setup"
        )

        print(
            """
            [HordePortalIngress] setup complete
              enemyID: \(enemyID)
              portalID: \(portalID)
              roomVisualEnabledFromStart: true
              portalInstanceEnabledFromStart: true
              oneController: true
              oneAnimationSource: true
              depthFeetRange: \(HordePortalIngressDepth.minFeet)-\(HordePortalIngressDepth.maxFeet)
              depthFeet: \(depthMeters / HordePortalIngressDepth.feetToMeters)
              noEnablePop: true
              noFade: true
            """
        )
    }

    func updateParallel(
        deltaTime: Float
    ) {
        portalLocalPosition.x += side.walkDirectionLocalX * parallelSpeed * deltaTime

        let reachedCenter =
            side == .left
            ? portalLocalPosition.x >= 0
            : portalLocalPosition.x <= 0

        if reachedCenter {
            portalLocalPosition.x = 0

            if turnHasStarted == false {
                startSingleNinetyDegreeTurn()
            }

            return
        }

        applyAuthoritativeWorldPose(
            localDirection: SIMD3<Float>(
                side.walkDirectionLocalX,
                0,
                0
            )
        )
    }

    func startSingleNinetyDegreeTurn() {
        guard turnHasStarted == false else {
            print(
                """
                [HordePortalIngress] duplicate turn start blocked
                  enemyID: \(enemyID)
                  portalID: \(portalID)
                """
            )
            return
        }

        turnHasStarted = true
        turnHasFinished = false
        phase = .turningTowardExit
        turnTimer = 0

        let fromDirection = SIMD3<Float>(
            side.walkDirectionLocalX,
            0,
            0
        )
        let toDirection = HordePortalLocalAxes.outToRoom
        let clipID = HordePortalTurnResolver.clipID(
            from: fromDirection,
            to: toDirection
        )

        turnClipID = clipID
        turnDuration = enemy.durationForClip(
            id: clipID
        ) ?? 1.0

        turnStartYaw = Self.yawOnlyOrientation(
            portalRoot: portal.root,
            portalLocalDirection: fromDirection
        )
        turnEndYaw = Self.yawOnlyOrientation(
            portalRoot: portal.root,
            portalLocalDirection: toDirection
        )
        worldOrientation = turnStartYaw

        enemy.playHordePortalTurnClip(
            id: clipID
        )

        print(
            """
            [HordePortalIngress] single 90-degree turn started
              enemyID: \(enemyID)
              portalID: \(portalID)
              clipID: \(clipID)
              rootYawDuringClip: held_constant
              programmaticYawSlerp: false
              walkLoopStoppedForTurn: true
              duplicateTurnBlocked: true
            """
        )
    }

    func updateTurn(
        deltaTime: Float
    ) {
        turnTimer += deltaTime

        updateWorldPositionOnly()

        // The turn clip owns the visible body rotation. The root yaw is held
        // constant until the clip finishes, then committed once.
        worldOrientation = turnStartYaw

        enemy.rootEntity.setPosition(
            worldPosition,
            relativeTo: nil
        )
        enemy.rootEntity.setOrientation(
            worldOrientation,
            relativeTo: nil
        )
        enemy.lockRootToFloorY(floorY)

        if turnTimer >= turnDuration {
            finishSingleNinetyDegreeTurn()
        }
    }

    func finishSingleNinetyDegreeTurn() {
        guard turnHasFinished == false else {
            return
        }

        turnHasFinished = true
        worldOrientation = turnEndYaw

        enemy.rootEntity.setPosition(
            worldPosition,
            relativeTo: nil
        )
        enemy.rootEntity.setOrientation(
            worldOrientation,
            relativeTo: nil
        )
        enemy.lockRootToFloorY(floorY)

        phase = .crossingAperture
        enemy.playHordePortalWalkLoop()

        print(
            """
            [HordePortalIngress] single 90-degree turn finished
              enemyID: \(enemyID)
              portalID: \(portalID)
              committedExitYawOnce: true
              walkLoopStartedAfterTurn: true
              duplicateTurn: false
              programmaticTurnDuringClip: false
            """
        )
    }

    func updateCrossing(
        deltaTime: Float,
        playerWorldPosition: SIMD3<Float>
    ) {
        portalLocalPosition.z += crossingSpeed * deltaTime

        applyAuthoritativeWorldPose(
            localDirection: HordePortalLocalAxes.outToRoom
        )

        if portalLocalPosition.z >= removeInstanceZ {
            finishExit(
                playerWorldPosition: playerWorldPosition
            )
        }
    }

    func applyAuthoritativeWorldPose(
        localDirection: SIMD3<Float>
    ) {
        updateWorldPositionOnly()

        worldOrientation = Self.yawOnlyOrientation(
            portalRoot: portal.root,
            portalLocalDirection: localDirection
        )

        enemy.rootEntity.setPosition(
            worldPosition,
            relativeTo: nil
        )

        enemy.rootEntity.setOrientation(
            worldOrientation,
            relativeTo: nil
        )

        enemy.lockRootToFloorY(floorY)
    }

    func updateWorldPositionOnly() {
        let rawWorld = portal.root.convert(
            position: portalLocalPosition,
            to: nil
        )

        worldPosition = SIMD3<Float>(
            rawWorld.x,
            enemy.rootYForFloorY(floorY),
            rawWorld.z
        )
    }

    func syncInstanceFromSource() {
        guard let portalInstance else {
            return
        }

        portalInstance.syncFromSource(
            worldPosition: worldPosition,
            worldOrientation: worldOrientation,
            portalWorldRoot: portal.portalWorldRoot
        )
    }

    func assertBothVisualsAlwaysOn(
        context: String
    ) {
        if enemy.rootEntity.isEnabled == false {
            fatalError(
                """
                [HordePortalIngress] ERROR room enemy visual was disabled
                  context: \(context)
                  requirement: both_visuals_always_on
                """
            )
        }

        guard let portalInstance else {
            fatalError(
                """
                [HordePortalIngress] ERROR portal instance missing while ingress is active
                  context: \(context)
                  requirement: both_visuals_always_on
                """
            )
        }

        if portalInstance.rootEntity.isEnabled == false {
            fatalError(
                """
                [HordePortalIngress] ERROR portal instance visual was disabled
                  context: \(context)
                  requirement: both_visuals_always_on
                """
            )
        }
    }

    func finishExit(
        playerWorldPosition: SIMD3<Float>
    ) {
        enemy.rootEntity.isEnabled = true

        enemy.setRootMotionEnabled(true)
        enemy.setExternalMotionDriven(false)
        enemy.setCombatEnabled(true)

        worldOrientation = Self.yawOnlyOrientationFacingPlayer(
            from: worldPosition,
            to: playerWorldPosition
        )

        enemy.rootEntity.setPosition(
            worldPosition,
            relativeTo: nil
        )
        enemy.rootEntity.setOrientation(
            worldOrientation,
            relativeTo: nil
        )
        enemy.lockRootToFloorY(floorY)

        portalInstance?.removeAfterExit()
        portalInstance = nil

        do {
            try enemy.finishHordePortalIngressAndStartFollow()
        } catch {
            print(
                """
                [HordePortalIngress] ERROR follow start failed after render instance exit
                  enemyID: \(enemyID)
                  portalID: \(portalID)
                  error: \(error.localizedDescription)
                """
            )
            phase = .failed
            return
        }

        phase = .realWorldFollowing

        print(
            """
            [HordePortalIngress] exit complete
              enemyID: \(enemyID)
              portalID: \(portalID)
              roomVisualWasAlwaysEnabled: true
              removedInstanceOnly: true
              removedPortalInstanceOnly: true
              noEnablePop: true
              noFade: true
              noDuplicateTurn: true
              combatEnabled: true
            """
        )
    }

    static func yawOnlyOrientation(
        portalRoot: Entity,
        portalLocalDirection: SIMD3<Float>
    ) -> simd_quatf {
        let worldOrigin = portalRoot.convert(
            position: .zero,
            to: nil
        )
        let worldTarget = portalRoot.convert(
            position: portalLocalDirection,
            to: nil
        )

        var flat = SIMD3<Float>(
            worldTarget.x - worldOrigin.x,
            0,
            worldTarget.z - worldOrigin.z
        )

        if simd_length(flat) < 0.001 {
            flat = HordePortalLocalAxes.characterForward
        } else {
            flat = simd_normalize(flat)
        }

        return simd_quatf(
            from: HordePortalLocalAxes.characterForward,
            to: flat
        )
    }

    static func yawOnlyOrientationFacingPlayer(
        from origin: SIMD3<Float>,
        to player: SIMD3<Float>
    ) -> simd_quatf {
        var flat = SIMD3<Float>(
            player.x - origin.x,
            0,
            player.z - origin.z
        )

        if simd_length(flat) < 0.001 {
            flat = HordePortalLocalAxes.characterForward
        } else {
            flat = simd_normalize(flat)
        }

        return simd_quatf(
            from: HordePortalLocalAxes.characterForward,
            to: flat
        )
    }
}
