import Foundation
import RealityKit
import simd

enum HordePortalIngressDepth {
    static let minDepth: Float = 5.0
    static let maxDepth: Float = 10.0
}

@MainActor
final class HordePortalSingleEnemyIngressController {
    enum Phase: String {
        case walkingParallelInsidePortal
        case turningTowardRoom
        case crossingAperture
        case following
        case failed
    }

    let enemyID: UUID
    let portalID: UUID
    let side: HordePortalEntranceSide

    private let enemy: JockRetargetTestController
    private let portal: HordePortal
    private weak var sceneRoot: Entity?

    private(set) var phase: Phase = .walkingParallelInsidePortal

    private var portalLocalPosition: SIMD3<Float>
    private let depthMeters: Float
    private let floorY: Float?
    private let parallelSpeed: Float
    private let crossingSpeed: Float
    private var turnTimer: Float = 0
    private var turnDuration: Float = 0.85

    init(
        enemy: JockRetargetTestController,
        portal: HordePortal,
        sceneRoot: Entity,
        side: HordePortalEntranceSide
    ) {
        self.enemy = enemy
        self.portal = portal
        self.sceneRoot = sceneRoot
        self.side = side
        self.enemyID = enemy.hordeBenchmarkID
        self.portalID = portal.id
        self.floorY = portal.resolvedFloorWorldY

        let depth = Float.random(
            in: HordePortalIngressDepth.minDepth...HordePortalIngressDepth.maxDepth
        )
        let startX = side.startLocalXSign * portal.placement.width * 0.72
        let localY = portal.localRootYForEnemy(
            enemy: enemy
        )

        self.depthMeters = depth
        self.portalLocalPosition = SIMD3<Float>(
            startX,
            localY,
            -depth
        )
        self.parallelSpeed = Float.random(in: 0.45...0.78)
        self.crossingSpeed = Float.random(in: 0.72...1.05)

        setup()
    }

    func update(
        deltaTime: Float,
        playerWorldPosition: SIMD3<Float>
    ) {
        switch phase {
        case .walkingParallelInsidePortal:
            updateParallel(
                deltaTime: deltaTime
            )

        case .turningTowardRoom:
            updateTurn(
                deltaTime: deltaTime
            )

        case .crossingAperture:
            updateCrossing(
                deltaTime: deltaTime,
                playerWorldPosition: playerWorldPosition
            )

        case .following, .failed:
            return
        }
    }
}

private extension HordePortalSingleEnemyIngressController {
    func setup() {
        if enemy.rootEntity.parent !== portal.portalWorldRoot {
            enemy.rootEntity.removeFromParent()
            portal.portalWorldRoot.addChild(enemy.rootEntity)
        }

        enemy.prepareForHordePortalIngress()
        enemy.setCombatEnabled(false)
        enemy.setExternalMotionDriven(true)
        enemy.setRootMotionEnabled(false)
        enemy.playHordePortalWalkLoop()

        applyPortalLocalPose(
            localDirection: SIMD3<Float>(
                side.walkDirectionLocalX,
                0,
                0
            )
        )

        print(
            """
            [HordePortalIngress] enemy spawned deep inside portal
              enemyID: \(enemyID)
              portalID: \(portalID)
              side: \(side.rawValue)
              depthMeters: \(depthMeters)
              localZ: \(portalLocalPosition.z)
              parent: portalWorldRoot
              apertureIsMask: true
              noWallOcclusionMask: true
              noProxy: true
              noOpacityFade: true
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
            startTurn()
            return
        }

        applyPortalLocalPose(
            localDirection: SIMD3<Float>(
                side.walkDirectionLocalX,
                0,
                0
            )
        )
    }

    func startTurn() {
        phase = .turningTowardRoom
        turnTimer = 0

        let from = SIMD3<Float>(
            side.walkDirectionLocalX,
            0,
            0
        )
        let to = HordePortalLocalAxes.outToRoom
        let clipID = HordePortalTurnResolver.clipID(
            from: from,
            to: to
        )

        turnDuration = enemy.durationForClip(
            id: clipID
        ) ?? 0.85

        enemy.playHordePortalTurnClip(
            id: clipID
        )

        print(
            """
            [HordePortalIngress] turn started inside portal
              enemyID: \(enemyID)
              portalID: \(portalID)
              clipID: \(clipID)
              noFade: true
              noProxy: true
            """
        )
    }

    func updateTurn(
        deltaTime: Float
    ) {
        turnTimer += deltaTime

        let t = min(
            1,
            turnTimer / max(
                turnDuration,
                0.001
            )
        )
        let startYaw = orientationFacingPortalLocalDirection(
            SIMD3<Float>(
                side.walkDirectionLocalX,
                0,
                0
            )
        )
        let endYaw = orientationFacingPortalLocalDirection(
            HordePortalLocalAxes.outToRoom
        )

        enemy.rootEntity.position = portalLocalPosition
        enemy.rootEntity.orientation = simd_slerp(
            startYaw,
            endYaw,
            t
        )

        if t >= 1 {
            phase = .crossingAperture
            enemy.playHordePortalWalkLoop()

            print(
                """
                [HordePortalIngress] turn complete inside portal
                  enemyID: \(enemyID)
                  portalID: \(portalID)
                  phase: crossingAperture
                """
            )
        }
    }

    func updateCrossing(
        deltaTime: Float,
        playerWorldPosition: SIMD3<Float>
    ) {
        portalLocalPosition.z += crossingSpeed * deltaTime

        applyPortalLocalPose(
            localDirection: HordePortalLocalAxes.outToRoom
        )

        if portalLocalPosition.z >= 0 {
            finishCrossingHandoff(
                playerWorldPosition: playerWorldPosition
            )
        }
    }

    func finishCrossingHandoff(
        playerWorldPosition: SIMD3<Float>
    ) {
        guard let sceneRoot else {
            phase = .failed
            print(
                """
                [HordePortalIngress] ERROR missing scene root during crossing handoff
                  enemyID: \(enemyID)
                  portalID: \(portalID)
                """
            )
            return
        }

        guard let floorY else {
            fatalError("[HordePortalIngress] missing floorY on portal exit")
        }

        let worldTransform = enemy.rootEntity.transformMatrix(
            relativeTo: nil
        )

        enemy.rootEntity.removeFromParent()
        sceneRoot.addChild(enemy.rootEntity)
        enemy.rootEntity.setTransformMatrix(
            worldTransform,
            relativeTo: nil
        )

        let worldPosition = enemy.rootEntity.position(
            relativeTo: nil
        )

        enemy.rootEntity.setPosition(
            SIMD3<Float>(
                worldPosition.x,
                enemy.rootYForFloorY(floorY),
                worldPosition.z
            ),
            relativeTo: nil
        )
        enemy.setOrientationYawOnlyFacingPlayer(
            playerWorldPosition
        )
        enemy.lockRootToFloorY(floorY)

        do {
            try enemy.finishHordePortalIngressAndStartFollow()
        } catch {
            print(
                """
                [HordePortalIngress] ERROR follow start failed after crossing handoff
                  enemyID: \(enemyID)
                  portalID: \(portalID)
                  error: \(error.localizedDescription)
                """
            )
            phase = .failed
            return
        }

        phase = .following

        print(
            """
            [HordePortalIngress] crossing handoff complete
              enemyID: \(enemyID)
              portalID: \(portalID)
              preservedWorldTransform: true
              noOpacityFade: true
              noProxy: true
              noWallOcclusionMask: true
              floorY: \(floorY)
            """
        )
    }

    func applyPortalLocalPose(
        localDirection: SIMD3<Float>
    ) {
        enemy.rootEntity.position = portalLocalPosition
        enemy.rootEntity.orientation = orientationFacingPortalLocalDirection(
            localDirection
        )
    }

    func orientationFacingPortalLocalDirection(
        _ direction: SIMD3<Float>
    ) -> simd_quatf {
        let desired = normalizePortalDirection(
            direction,
            fallback: HordePortalLocalAxes.outToRoom
        )

        return simd_quatf(
            from: HordePortalLocalAxes.characterForward,
            to: desired
        )
    }

    func normalizePortalDirection(
        _ direction: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let length = simd_length(direction)
        guard length > 0.0001 else {
            return fallback
        }

        return direction / length
    }
}
