import Foundation
import RealityKit
import simd

enum HordePortalIngressVisibilityState: String {
    case insidePortalMasked
    case crossingMask
    case realWorld
}

@MainActor
final class HordePortalWorldspaceIngressController {
    enum Phase: String {
        case walkingParallel
        case turningTowardExit
        case crossing
        case following
        case failed
    }

    let enemyID: UUID
    let portalID: UUID

    private let realEnemy: JockRetargetTestController
    private let portalEnemy: JockRetargetTestController
    private let portal: HordePortal
    private let side: HordePortalEntranceSide
    private weak var sceneRoot: Entity?

    private(set) var phase: Phase = .walkingParallel
    private var visibilityState: HordePortalIngressVisibilityState = .insidePortalMasked

    private var worldPosition: SIMD3<Float>
    private var worldYaw: simd_quatf
    private var portalLocalPosition: SIMD3<Float>
    private let floorY: Float

    private let parallelSpeed: Float
    private let crossSpeed: Float
    private var turnTimer: Float = 0
    private var turnDuration: Float = 0.85
    private var opacityBlend: Float = 0

    init(
        realEnemy: JockRetargetTestController,
        portalEnemy: JockRetargetTestController,
        portal: HordePortal,
        sceneRoot: Entity,
        side: HordePortalEntranceSide
    ) {
        self.realEnemy = realEnemy
        self.portalEnemy = portalEnemy
        self.portal = portal
        self.sceneRoot = sceneRoot
        self.side = side
        self.enemyID = realEnemy.hordeBenchmarkID
        self.portalID = portal.id
        self.floorY = portal.resolvedFloorWorldY ?? portal.placement.floorWorldY ?? 0

        let startX = side.startLocalXSign * portal.placement.width * 0.72
        let startY = portal.portalFloorLocalY + realEnemy.groundingProfile.rootYOffsetFromFloor
        let startZ: Float = -1.15
        self.portalLocalPosition = SIMD3<Float>(
            startX,
            startY,
            startZ
        )

        let world = portal.root.convert(
            position: portalLocalPosition,
            to: nil
        )
        self.worldPosition = SIMD3<Float>(
            world.x,
            realEnemy.rootYForFloorY(floorY),
            world.z
        )
        self.worldYaw = Self.yawOnlyOrientation(
            portalRoot: portal.root,
            portalLocalDirection: SIMD3<Float>(
                side.walkDirectionLocalX,
                0,
                0
            )
        )
        self.parallelSpeed = Float.random(in: 0.45...0.78)
        self.crossSpeed = Float.random(in: 0.55...0.85)

        configureEnemiesForIngress()
    }

    func update(
        deltaTime: Float,
        playerWorldPosition: SIMD3<Float>
    ) {
        switch phase {
        case .walkingParallel:
            updateParallel(
                deltaTime: deltaTime
            )

        case .turningTowardExit:
            updateTurn(
                deltaTime: deltaTime
            )

        case .crossing:
            updateCrossing(
                deltaTime: deltaTime
            )

        case .following, .failed:
            return
        }

        applyWorldPoseToBoth()
        portalEnemy.update(
            deltaTime: deltaTime,
            currentHeadPosition: playerWorldPosition
        )
    }

    private func configureEnemiesForIngress() {
        realEnemy.prepareForHordePortalIngress()
        portalEnemy.prepareForHordePortalIngress()

        realEnemy.setCombatEnabled(false)
        portalEnemy.setCombatEnabled(false)
        realEnemy.setExternalMotionDriven(true)
        portalEnemy.setExternalMotionDriven(true)
        realEnemy.setRootMotionEnabled(false)
        portalEnemy.setRootMotionEnabled(false)

        realEnemy.setRecursiveOpacity(0.0)
        portalEnemy.setRecursiveOpacity(1.0)

        applyWorldPoseToBoth()

        print(
            """
            [HordePortalIngress] worldspace ingress staged
              enemyID: \(enemyID)
              portalID: \(portalID)
              side: \(side.rawValue)
              visibilityState: \(visibilityState.rawValue)
              authoritativePose: world_space
              realEnemyInSceneRoot: \(realEnemy.rootEntity.parent === sceneRoot)
              portalProxyInPortalWorld: \(portalEnemy.rootEntity.parent === portal.portalWorldRoot)
              combatEnabled: false
            """
        )
    }

    private func updateParallel(
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
        }

        updateWorldPoseFromPortalLocal(
            localDirection: SIMD3<Float>(
                side.walkDirectionLocalX,
                0,
                0
            )
        )
    }

    private func startTurn() {
        phase = .turningTowardExit
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

        realEnemy.playHordePortalTurnClip(
            id: clipID
        )
        portalEnemy.playHordePortalTurnClip(
            id: clipID
        )

        print(
            """
            [HordePortalIngress] worldspace turn started
              enemyID: \(enemyID)
              portalID: \(portal.id)
              clipID: \(clipID)
              from: \(from)
              to: \(to)
            """
        )
    }

    private func updateTurn(
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
        let startYaw = Self.yawOnlyOrientation(
            portalRoot: portal.root,
            portalLocalDirection: SIMD3<Float>(
                side.walkDirectionLocalX,
                0,
                0
            )
        )
        let endYaw = Self.yawOnlyOrientation(
            portalRoot: portal.root,
            portalLocalDirection: HordePortalLocalAxes.outToRoom
        )

        worldYaw = simd_slerp(
            startYaw,
            endYaw,
            t
        )

        let world = portal.root.convert(
            position: portalLocalPosition,
            to: nil
        )
        worldPosition = SIMD3<Float>(
            world.x,
            realEnemy.rootYForFloorY(floorY),
            world.z
        )

        if t >= 1 {
            phase = .crossing
            realEnemy.playHordePortalWalkLoop()
            portalEnemy.playHordePortalWalkLoop()

            print(
                """
                [HordePortalIngress] worldspace turn complete
                  enemyID: \(enemyID)
                  portalID: \(portal.id)
                  phase: crossing
                """
            )
        }
    }

    private func updateCrossing(
        deltaTime: Float
    ) {
        portalLocalPosition.z += crossSpeed * deltaTime
        updateWorldPoseFromPortalLocal(
            localDirection: HordePortalLocalAxes.outToRoom
        )

        let fadeStart: Float = -0.06
        let fadeEnd: Float = 0.22
        let t = max(
            0,
            min(
                1,
                (portalLocalPosition.z - fadeStart) / (fadeEnd - fadeStart)
            )
        )

        opacityBlend = t
        visibilityState = t >= 1 ? .realWorld : .crossingMask

        realEnemy.setRecursiveOpacity(t)
        portalEnemy.setRecursiveOpacity(1.0 - t)

        if t >= 1 {
            finishExit()
        }
    }

    private func finishExit() {
        realEnemy.setRecursiveOpacity(1.0)
        portalEnemy.setRecursiveOpacity(0.0)
        portalEnemy.hide()
        portalEnemy.rootEntity.removeFromParent()

        realEnemy.rootEntity.setPosition(
            worldPosition,
            relativeTo: nil
        )
        realEnemy.rootEntity.setOrientation(
            worldYaw,
            relativeTo: nil
        )
        realEnemy.lockRootToFloorY(floorY)
        realEnemy.setCombatEnabled(true)

        do {
            try realEnemy.finishHordePortalIngressAndStartFollow()
        } catch {
            print(
                """
                [HordePortalIngress] ERROR worldspace follow start failed
                  enemyID: \(enemyID)
                  portalID: \(portal.id)
                  error: \(error.localizedDescription)
                """
            )
            phase = .failed
            return
        }

        phase = .following
        visibilityState = .realWorld

        print(
            """
            [HordePortalIngress] worldspace exit complete
              enemyID: \(enemyID)
              portalID: \(portal.id)
              finalWorldPosition: \(worldPosition)
              floorY: \(floorY)
              opacityBlend: \(opacityBlend)
              opacityMaskDeactivated: true
              noReparentJump: true
              combatEnabled: true
            """
        )
    }

    private func updateWorldPoseFromPortalLocal(
        localDirection: SIMD3<Float>
    ) {
        let world = portal.root.convert(
            position: portalLocalPosition,
            to: nil
        )

        worldPosition = SIMD3<Float>(
            world.x,
            realEnemy.rootYForFloorY(floorY),
            world.z
        )
        worldYaw = Self.yawOnlyOrientation(
            portalRoot: portal.root,
            portalLocalDirection: localDirection
        )
    }

    private func applyWorldPoseToBoth() {
        realEnemy.rootEntity.setPosition(
            worldPosition,
            relativeTo: nil
        )
        realEnemy.rootEntity.setOrientation(
            worldYaw,
            relativeTo: nil
        )

        let portalLocal = portal.portalWorldRoot.convert(
            position: worldPosition,
            from: nil
        )
        let portalWorldOrientation = portal.portalWorldRoot.orientation(
            relativeTo: nil
        )
        let portalLocalOrientation = simd_inverse(portalWorldOrientation) * worldYaw

        portalEnemy.rootEntity.position = portalLocal
        portalEnemy.rootEntity.orientation = portalLocalOrientation
    }

    private static func yawOnlyOrientation(
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
}
