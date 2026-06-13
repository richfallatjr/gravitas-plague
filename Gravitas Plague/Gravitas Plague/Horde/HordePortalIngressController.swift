import Foundation
import RealityKit
import simd

@MainActor
final class HordePortalIngressController {
    enum Phase: String {
        case walkingParallelInsidePortal
        case turningAtPortalCenter
        case crossingIntoRoom
        case followingPlayer
        case complete
        case failed
    }

    let enemyID: UUID
    let portalID: UUID
    let side: HordePortalEntranceSide

    private(set) var phase: Phase = .walkingParallelInsidePortal

    private weak var enemy: JockRetargetTestController?
    private let portal: HordePortal
    private weak var sceneRoot: Entity?

    private var localPosition: SIMD3<Float>
    private let parallelSpeed: Float
    private let crossSpeed: Float
    private var turnStarted = false
    private var turnElapsed: Float = 0
    private let turnDuration: Float = 0.85

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

        let startX = side.startLocalXSign * portal.placement.width * 0.72
        let startY = portal.localRootYForEnemy(
            enemy: enemy
        )
        let startZ: Float = -1.20

        self.localPosition = SIMD3<Float>(
            startX,
            startY,
            startZ
        )

        self.parallelSpeed = Float.random(in: 0.45...0.78)
        self.crossSpeed = Float.random(in: 0.55...0.85)

        setupEnemyInsidePortalWorld()
    }

    private var currentWalkDirectionLocal: SIMD3<Float> {
        SIMD3<Float>(
            side.walkDirectionLocalX,
            0,
            0
        )
    }

    private var exitDirectionLocal: SIMD3<Float> {
        HordePortalLocalAxes.outToRoom
    }

    func update(
        deltaTime: Float,
        playerWorldPosition: SIMD3<Float>
    ) {
        guard let enemy else {
            phase = .failed
            return
        }

        switch phase {
        case .walkingParallelInsidePortal:
            updateParallelWalk(
                enemy: enemy,
                deltaTime: deltaTime
            )

        case .turningAtPortalCenter:
            updateTurn(
                deltaTime: deltaTime
            )

        case .crossingIntoRoom:
            updateCrossIntoRoom(
                enemy: enemy,
                deltaTime: deltaTime,
                playerWorldPosition: playerWorldPosition
            )

        case .followingPlayer, .complete, .failed:
            return
        }
    }

    private func setupEnemyInsidePortalWorld() {
        guard let enemy else {
            phase = .failed
            return
        }

        enemy.rootEntity.removeFromParent()
        portal.portalWorldRoot.addChild(enemy.rootEntity)

        enemy.rootEntity.isEnabled = true
        enemy.rootEntity.position = localPosition
        enemy.rootEntity.orientation = orientationFacingPortalLocalDirection(
            currentWalkDirectionLocal
        )

        enemy.prepareForHordePortalIngress()
        enemy.setRootMotionEnabled(false)

        print(
            """
            [HordePortalIngress] enemy staged inside portal
              enemyID: \(enemyID)
              portalID: \(portalID)
              side: \(side.rawValue)
              localPosition: \(localPosition)
              phase: \(phase.rawValue)
              visibleOnlyThroughPortal: true
            """
        )

        print(
            """
            [HordePortalIngress] staged with explicit portal-local direction
              enemyID: \(enemyID)
              side: \(side.rawValue)
              walkDirectionLocal: \(currentWalkDirectionLocal)
              characterForwardAxis: -Z
              localPosition: \(localPosition)
              externalMotionDriven: true
            """
        )
    }

    private func updateParallelWalk(
        enemy: JockRetargetTestController,
        deltaTime: Float
    ) {
        localPosition.x += side.walkDirectionLocalX * parallelSpeed * deltaTime

        let crossedCenter =
            side == .left
            ? localPosition.x >= 0
            : localPosition.x <= 0

        if crossedCenter {
            localPosition.x = 0
            phase = .turningAtPortalCenter

            enemy.rootEntity.position = localPosition
            startTurn(enemy: enemy)
            return
        }

        enemy.rootEntity.position = localPosition
    }

    private func startTurn(
        enemy: JockRetargetTestController
    ) {
        guard !turnStarted else {
            return
        }

        turnStarted = true
        turnElapsed = 0
        enemy.setRootMotionEnabled(false)

        let turnClipID = HordePortalTurnResolver.clipID(
            from: currentWalkDirectionLocal,
            to: exitDirectionLocal
        )
        let yaw = HordePortalTurnResolver.signedYawRadians(
            from: currentWalkDirectionLocal,
            to: exitDirectionLocal
        )

        enemy.playHordePortalTurnClip(id: turnClipID)

        print(
            """
            [HordePortalIngress] turn started
              enemyID: \(enemyID)
              portalID: \(portalID)
              side: \(side.rawValue)
              fromDirection: \(currentWalkDirectionLocal)
              toDirection: \(exitDirectionLocal)
              signedYawRadians: \(yaw)
              clipID: \(turnClipID)
            """
        )
    }

    private func updateTurn(
        deltaTime: Float
    ) {
        turnElapsed += deltaTime

        guard turnElapsed >= turnDuration else {
            return
        }

        finishTurn()
    }

    private func finishTurn() {
        guard let enemy else {
            phase = .failed
            return
        }

        enemy.rootEntity.orientation = orientationFacingPortalLocalDirection(
            exitDirectionLocal
        )
        enemy.playHordePortalWalkLoop()

        phase = .crossingIntoRoom

        print(
            """
            [HordePortalIngress] turn complete
              enemyID: \(enemyID)
              portalID: \(portalID)
              finalFacingLocal: \(exitDirectionLocal)
              phase: \(phase.rawValue)
            """
        )
    }

    private func updateCrossIntoRoom(
        enemy: JockRetargetTestController,
        deltaTime: Float,
        playerWorldPosition: SIMD3<Float>
    ) {
        localPosition.z += crossSpeed * deltaTime
        enemy.rootEntity.position = localPosition

        if localPosition.z >= 0.12 {
            moveEnemyIntoRoom(
                enemy: enemy,
                playerWorldPosition: playerWorldPosition
            )
        }
    }

    private func moveEnemyIntoRoom(
        enemy: JockRetargetTestController,
        playerWorldPosition: SIMD3<Float>
    ) {
        guard let sceneRoot else {
            phase = .failed
            return
        }

        let localExit = SIMD3<Float>(
            0,
            localPosition.y,
            0.22
        )

        let rawWorldExit = portal.root.convert(
            position: localExit,
            to: nil
        )

        guard let floorY = portal.resolvedFloorWorldY else {
            print(
                """
                [HordePortalIngress] ERROR no portal floorY on exit
                  portalID: \(portalID)
                  action: keeping enemy inside portal
                """
            )
            return
        }

        let finalRootY = enemy.rootYForFloorY(floorY)
        let worldExit = SIMD3<Float>(
            rawWorldExit.x,
            finalRootY,
            rawWorldExit.z
        )
        let yawOnly = uprightYawOrientationFacing(
            from: worldExit,
            to: playerWorldPosition
        )
        let pitchRoll = debugPitchRollFromQuaternion(yawOnly)

        enemy.rootEntity.removeFromParent()
        sceneRoot.addChild(enemy.rootEntity)

        enemy.rootEntity.setPosition(
            worldExit,
            relativeTo: nil
        )
        enemy.rootEntity.setOrientation(
            yawOnly,
            relativeTo: nil
        )
        enemy.lockRootToFloorY(floorY)
        enemy.setExternalMotionDriven(false)
        enemy.setRootMotionEnabled(true)

        if abs(pitchRoll.pitch) > 0.02 ||
           abs(pitchRoll.roll) > 0.02 {
            print(
                """
                [HordePortalIngress] ERROR exit orientation is not upright
                  pitch: \(pitchRoll.pitch)
                  roll: \(pitchRoll.roll)
                """
            )
        }

        do {
            try enemy.finishHordePortalIngressAndStartFollow()
        } catch {
            print(
                """
                [HordePortalIngress] ERROR failed to start follow after portal exit
                  enemyID: \(enemyID)
                  portalID: \(portalID)
                  error: \(error.localizedDescription)
                """
            )
            phase = .failed
            return
        }

        phase = .followingPlayer

        print(
            """
            [HordePortalIngress] exit grounding
              enemyID: \(enemyID)
              rawWorldExitY: \(rawWorldExit.y)
              floorY: \(floorY)
              rootYOffsetFromFloor: \(enemy.groundingProfile.rootYOffsetFromFloor)
              finalRootY: \(enemy.rootEntity.position(relativeTo: nil).y)
            """
        )

        print(
            """
            [HordePortalIngress] enemy exited portal upright
              enemyID: \(enemyID)
              portalID: \(portalID)
              rawWorldExit: \(rawWorldExit)
              floorY: \(floorY)
              finalRootY: \(finalRootY)
              yawOnlyQuaternion: \(yawOnly.vector)
              pitchRollRemoved: true
              phase: \(phase.rawValue)
            """
        )
    }

    private func uprightYawOrientationFacing(
        from origin: SIMD3<Float>,
        to target: SIMD3<Float>
    ) -> simd_quatf {
        var flat = SIMD3<Float>(
            target.x - origin.x,
            0,
            target.z - origin.z
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

    private func debugPitchRollFromQuaternion(
        _ quaternion: simd_quatf
    ) -> (pitch: Float, roll: Float) {
        let matrix = float3x3(quaternion)
        let forward = -SIMD3<Float>(
            matrix.columns.2.x,
            matrix.columns.2.y,
            matrix.columns.2.z
        )
        let right = SIMD3<Float>(
            matrix.columns.0.x,
            matrix.columns.0.y,
            matrix.columns.0.z
        )
        let pitch = asin(
            max(
                -1,
                min(
                    1,
                    forward.y
                )
            )
        )
        let roll = asin(
            max(
                -1,
                min(
                    1,
                    right.y
                )
            )
        )

        return (
            pitch,
            roll
        )
    }

    private func orientationFacingPortalLocalDirection(
        _ direction: SIMD3<Float>
    ) -> simd_quatf {
        let desired = normalizeSafe(
            direction,
            fallback: HordePortalLocalAxes.outToRoom
        )

        return simd_quatf(
            from: HordePortalLocalAxes.characterForward,
            to: desired
        )
    }
}

private func normalizeSafe(
    _ vector: SIMD3<Float>,
    fallback: SIMD3<Float>
) -> SIMD3<Float> {
    let length = simd_length(vector)
    guard length > 0.0001 else {
        return fallback
    }

    return vector / length
}
