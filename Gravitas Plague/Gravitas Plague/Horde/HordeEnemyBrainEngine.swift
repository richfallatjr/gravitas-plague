import Foundation
import simd

struct HordeEnemyBrainCommands: Sendable {
    let frameIndex: Int
    let commands: [EnemyBrainCommand]
}

struct EnemyBrainBatchRequest: Sendable {
    let frame: FrameClockSnapshot
    let player: PlayerPoseSnapshot
    let enemies: [EnemyBrainSnapshot]
    let bodyObstacles: [EnemyBodySnapshot]
}

enum HordeBrainMoveMode: String, Sendable {
    case directToTarget
    case flankLeft
    case flankRight
    case pivotLeft
    case pivotRight
}

struct EnemyBrainFollowIntent: Sendable {
    let moveMode: HordeBrainMoveMode
    let movementDirectionWorld: SIMD3<Float>
    let nextYawRadians: Float
    let distanceToUserXZ: Float
    let remainingSafeTravelMeters: Float
    let directCoastClear: Bool
    let blockingEnemyID: UUID?
}

extension EnemyBrainFollowIntent {
    func consumingTravel(
        _ meters: Float
    ) -> EnemyBrainFollowIntent {
        EnemyBrainFollowIntent(
            moveMode: moveMode,
            movementDirectionWorld: movementDirectionWorld,
            nextYawRadians: nextYawRadians,
            distanceToUserXZ: distanceToUserXZ,
            remainingSafeTravelMeters: max(
                0,
                remainingSafeTravelMeters - meters
            ),
            directCoastClear: directCoastClear,
            blockingEnemyID: blockingEnemyID
        )
    }
}

enum EnemyBrainCommand: Sendable {
    case applyFollowIntent(
        enemyID: UUID,
        intent: EnemyBrainFollowIntent
    )
    case enterCloseRangeReady(
        enemyID: UUID,
        attackAnchorUserPosition: SIMD3<Float>,
        delaySeconds: TimeInterval
    )
    case setCloseRangeDelay(
        enemyID: UUID,
        delaySeconds: TimeInterval
    )
    case startAttack(
        enemyID: UUID,
        attackAnchorUserPosition: SIMD3<Float>?
    )
    case exitCloseRangeToFollow(enemyID: UUID)
    case clearAttackAnchor(enemyID: UUID)
    case advanceActiveAttackElapsed(
        enemyID: UUID,
        deltaSeconds: TimeInterval
    )
}

actor HordeEnemyBrainEngine {
    private var lastFollowIntentByEnemyID: [UUID: EnemyBrainFollowIntent] = [:]
    private var lastFlankSideByEnemyID: [UUID: Int] = [:]

    func step(
        frame: FrameClockSnapshot,
        player: PlayerPoseSnapshot,
        enemies: [EnemyBrainSnapshot]
    ) -> HordeEnemyBrainCommands {
        let request = EnemyBrainBatchRequest(
            frame: frame,
            player: player,
            enemies: enemies,
            bodyObstacles: []
        )

        return step(request)
    }

    func step(
        _ request: EnemyBrainBatchRequest
    ) -> HordeEnemyBrainCommands {
        let commands = request.enemies.flatMap { enemy in
            EnemyBrainDecisionEngine.commands(
                frame: request.frame,
                player: request.player,
                enemy: enemy,
                bodyObstacles: request.bodyObstacles,
                previousFollowIntent: lastFollowIntentByEnemyID[enemy.id],
                previousFlankSide: lastFlankSideByEnemyID[enemy.id]
            )
        }

        updateState(
            commands: commands,
            liveEnemyIDs: Set(request.enemies.map(\.id))
        )

        return HordeEnemyBrainCommands(
            frameIndex: request.frame.frameIndex,
            commands: commands
        )
    }

    func reset() {
        lastFollowIntentByEnemyID.removeAll()
        lastFlankSideByEnemyID.removeAll()
    }

    private func updateState(
        commands: [EnemyBrainCommand],
        liveEnemyIDs: Set<UUID>
    ) {
        lastFollowIntentByEnemyID = lastFollowIntentByEnemyID.filter {
            liveEnemyIDs.contains($0.key)
        }

        lastFlankSideByEnemyID = lastFlankSideByEnemyID.filter {
            liveEnemyIDs.contains($0.key)
        }

        for command in commands {
            switch command {
            case .applyFollowIntent(let enemyID, let intent):
                lastFollowIntentByEnemyID[enemyID] = intent

                switch intent.moveMode {
                case .flankLeft, .pivotLeft:
                    lastFlankSideByEnemyID[enemyID] = -1
                case .flankRight, .pivotRight:
                    lastFlankSideByEnemyID[enemyID] = 1
                case .directToTarget:
                    break
                }

            case .enterCloseRangeReady(let enemyID, _, _),
                 .setCloseRangeDelay(let enemyID, _),
                 .startAttack(let enemyID, _),
                 .exitCloseRangeToFollow(let enemyID),
                 .clearAttackAnchor(let enemyID),
                 .advanceActiveAttackElapsed(let enemyID, _):
                lastFollowIntentByEnemyID.removeValue(
                    forKey: enemyID
                )
            }
        }
    }
}

private enum EnemyBrainDecisionEngine {
    static func commands(
        frame: FrameClockSnapshot,
        player: PlayerPoseSnapshot,
        enemy: EnemyBrainSnapshot,
        bodyObstacles: [EnemyBodySnapshot],
        previousFollowIntent: EnemyBrainFollowIntent?,
        previousFlankSide: Int?
    ) -> [EnemyBrainCommand] {
        guard enemy.isActiveHordeLifecycle,
              !enemy.isDead,
              !enemy.isHitReacting else {
            return []
        }

        switch enemy.state {
        case .dead, .hitReaction, .inactive:
            return []

        case .attacking:
            var commands: [EnemyBrainCommand] = [
                .advanceActiveAttackElapsed(
                    enemyID: enemy.id,
                    deltaSeconds: TimeInterval(frame.deltaTime)
                )
            ]

            if userMovedFromAttackAnchor(
                playerPosition: player.position,
                enemy: enemy
            ) {
                commands.append(
                    .clearAttackAnchor(
                        enemyID: enemy.id
                    )
                )
            }

            return commands

        case .closeRangeReady:
            guard enemy.attackEnabled else {
                return [
                    .exitCloseRangeToFollow(
                        enemyID: enemy.id
                    )
                ]
            }

            if userMovedFromAttackAnchor(
                playerPosition: player.position,
                enemy: enemy
            ) {
                return [
                    .exitCloseRangeToFollow(
                        enemyID: enemy.id
                    )
                ]
            }

            let distance = crowdDistanceXZ(
                enemy.position,
                player.position
            )

            if distance > enemy.resumeFollowDistanceMeters {
                return [
                    .exitCloseRangeToFollow(
                        enemyID: enemy.id
                    )
                ]
            }

            return [
                .startAttack(
                    enemyID: enemy.id,
                    attackAnchorUserPosition: enemy.attackAnchorUserPosition
                )
            ]

        case .idleStopped, .waitingToFollow, .following:
            let distance = crowdDistanceXZ(
                enemy.position,
                player.position
            )

            guard enemy.attackEnabled else {
                return followCommands(
                    frame: frame,
                    player: player,
                    enemy: enemy,
                    bodyObstacles: bodyObstacles,
                    distance: distance,
                    previousFollowIntent: previousFollowIntent,
                    previousFlankSide: previousFlankSide
                )
            }

            guard distance <= enemy.attackProximityMeters else {
                return followCommands(
                    frame: frame,
                    player: player,
                    enemy: enemy,
                    bodyObstacles: bodyObstacles,
                    distance: distance,
                    previousFollowIntent: previousFollowIntent,
                    previousFlankSide: previousFlankSide
                )
            }

            return [
                .startAttack(
                    enemyID: enemy.id,
                    attackAnchorUserPosition: player.position
                )
            ]
        }
    }

    private static func followCommands(
        frame: FrameClockSnapshot,
        player: PlayerPoseSnapshot,
        enemy: EnemyBrainSnapshot,
        bodyObstacles: [EnemyBodySnapshot],
        distance: Float,
        previousFollowIntent: EnemyBrainFollowIntent?,
        previousFlankSide: Int?
    ) -> [EnemyBrainCommand] {
        let intent = followIntentUsingRayProbe(
            frame: frame,
            player: player,
            enemy: enemy,
            bodyObstacles: bodyObstacles,
            distance: distance,
            previousFollowIntent: previousFollowIntent,
            previousFlankSide: previousFlankSide
        )

        return [
            .applyFollowIntent(
                enemyID: enemy.id,
                intent: intent
            )
        ]
    }

    private static func followIntentUsingRayProbe(
        frame: FrameClockSnapshot,
        player: PlayerPoseSnapshot,
        enemy: EnemyBrainSnapshot,
        bodyObstacles: [EnemyBodySnapshot],
        distance: Float,
        previousFollowIntent: EnemyBrainFollowIntent?,
        previousFlankSide: Int?
    ) -> EnemyBrainFollowIntent {
        let directToPlayer = flatNormalize(
            player.position - enemy.position,
            fallback:
                previousFollowIntent?.movementDirectionWorld ??
                yawForward(
                    yawRadians: enemy.yawRadians
                )
        )

        let directProbeEnd =
            enemy.position +
            directToPlayer * min(
                max(enemy.probeForwardLengthMeters, 0.25),
                max(distance, 0.25)
            )

        let directBlocker = firstBlockingBody(
            from: enemy.position,
            to: directProbeEnd,
            selfID: enemy.id,
            selfRadius: enemy.bodyRadiusMeters,
            obstacles: bodyObstacles
        )

        if directBlocker == nil {
            let movementDirection = rotateFlat(
                directToPlayer,
                radians: enemy.crowdSteerAngleRadians
            )

            return makeFollowIntent(
                moveMode: .directToTarget,
                direction: movementDirection,
                frame: frame,
                enemy: enemy,
                distance: distance,
                directCoastClear: true,
                blockingEnemyID: nil
            )
        }

        let selectedSide = chooseFlankSide(
            enemy: enemy,
            directDirection: directToPlayer,
            blocker: directBlocker,
            previousFlankSide: previousFlankSide
        )

        if let flank = flankIntent(
            side: selectedSide,
            direct: directToPlayer,
            frame: frame,
            enemy: enemy,
            bodyObstacles: bodyObstacles,
            distance: distance,
            blockingEnemyID: directBlocker?.id
        ) {
            return flank
        }

        if let opposite = flankIntent(
            side: -selectedSide,
            direct: directToPlayer,
            frame: frame,
            enemy: enemy,
            bodyObstacles: bodyObstacles,
            distance: distance,
            blockingEnemyID: directBlocker?.id
        ) {
            return opposite
        }

        let lateral = lateralDirection(
            direct: directToPlayer,
            side: selectedSide
        )

        let pivotDirection =
            validDirection(previousFollowIntent?.movementDirectionWorld) ??
            lateral

        return makeFollowIntent(
            moveMode: selectedSide < 0 ? .pivotLeft : .pivotRight,
            direction: pivotDirection,
            frame: frame,
            enemy: enemy,
            distance: distance,
            directCoastClear: false,
            blockingEnemyID: directBlocker?.id
        )
    }

    private static func flankIntent(
        side: Int,
        direct: SIMD3<Float>,
        frame: FrameClockSnapshot,
        enemy: EnemyBrainSnapshot,
        bodyObstacles: [EnemyBodySnapshot],
        distance: Float,
        blockingEnemyID: UUID?
    ) -> EnemyBrainFollowIntent? {
        let lateral = lateralDirection(
            direct: direct,
            side: side
        )

        var direction =
            direct * HordeEnemyBrainSettings.blockedForwardBlend +
            lateral * HordeEnemyBrainSettings.blockedLateralBlend

        direction = flatNormalize(
            direction,
            fallback: lateral
        )

        let probeEnd =
            enemy.position +
            direction * max(
                enemy.probeSideLengthMeters,
                HordeEnemyBrainSettings.minimumTravelBudgetMeters
            )

        let blocker = firstBlockingBody(
            from: enemy.position,
            to: probeEnd,
            selfID: enemy.id,
            selfRadius: enemy.bodyRadiusMeters,
            obstacles: bodyObstacles
        )

        guard blocker == nil else {
            return nil
        }

        return makeFollowIntent(
            moveMode: side < 0 ? .flankLeft : .flankRight,
            direction: direction,
            frame: frame,
            enemy: enemy,
            distance: distance,
            directCoastClear: false,
            blockingEnemyID: blockingEnemyID
        )
    }

    private static func firstBlockingBody(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        selfID: UUID,
        selfRadius: Float,
        obstacles: [EnemyBodySnapshot]
    ) -> EnemyBodySnapshot? {
        var nearest: EnemyBodySnapshot?
        var nearestT = Float.greatestFiniteMagnitude

        for obstacle in obstacles {
            guard obstacle.id != selfID,
                  obstacle.isAlive else {
                continue
            }

            let obstacleRadius = max(
                obstacle.halfWidth,
                obstacle.halfDepth
            )

            let radius =
                selfRadius +
                obstacleRadius +
                HordeEnemyBrainSettings.rayBodyPaddingMeters

            guard let t = segmentCircleHitT(
                start: start,
                end: end,
                center: obstacle.centerWorld,
                radius: radius
            ) else {
                continue
            }

            if t < nearestT {
                nearestT = t
                nearest = obstacle
            }
        }

        return nearest
    }

    private static func segmentCircleHitT(
        start: SIMD3<Float>,
        end: SIMD3<Float>,
        center: SIMD3<Float>,
        radius: Float
    ) -> Float? {
        let a = SIMD2<Float>(start.x, start.z)
        let b = SIMD2<Float>(end.x, end.z)
        let c = SIMD2<Float>(center.x, center.z)

        let ab = b - a
        let abLenSq = simd_length_squared(ab)

        guard abLenSq > 0.000001 else {
            return nil
        }

        let t = max(
            0,
            min(
                1,
                simd_dot(c - a, ab) / abLenSq
            )
        )

        let closest = a + ab * t
        let distSq = simd_length_squared(c - closest)

        return distSq <= radius * radius ? t : nil
    }

    private static func makeFollowIntent(
        moveMode: HordeBrainMoveMode,
        direction: SIMD3<Float>,
        frame: FrameClockSnapshot,
        enemy: EnemyBrainSnapshot,
        distance: Float,
        directCoastClear: Bool,
        blockingEnemyID: UUID?
    ) -> EnemyBrainFollowIntent {
        let movementDirection = flatNormalize(
            direction,
            fallback: yawForward(
                yawRadians: enemy.yawRadians
            )
        )

        let targetYaw = PhaseOneMath.yawRadiansForNegativeZForward(
            worldForward: movementDirection
        )

        let deltaYaw = PhaseOneMath.normalizedAngleRadians(
            targetYaw - enemy.yawRadians
        )

        let nextYaw: Float

        if abs(deltaYaw) <= enemy.facingDeadZoneRadians {
            nextYaw = enemy.yawRadians
        } else {
            let maxStep =
                enemy.maxTurnRadiansPerSecond *
                Float(HordeEnemyBrainSettings.decisionIntervalSeconds)

            let clampedStep = min(
                max(deltaYaw, -maxStep),
                maxStep
            )

            nextYaw = PhaseOneMath.normalizedAngleRadians(
                enemy.yawRadians + clampedStep
            )
        }

        let travelToAttackRange =
            distance - enemy.attackProximityMeters

        let safeTravel = min(
            HordeEnemyBrainSettings.maximumTravelBudgetMeters,
            max(
                HordeEnemyBrainSettings.minimumTravelBudgetMeters,
                travelToAttackRange
            )
        )

        return EnemyBrainFollowIntent(
            moveMode: moveMode,
            movementDirectionWorld: movementDirection,
            nextYawRadians: nextYaw,
            distanceToUserXZ: distance,
            remainingSafeTravelMeters: safeTravel,
            directCoastClear: directCoastClear,
            blockingEnemyID: blockingEnemyID
        )
    }

    private static func chooseFlankSide(
        enemy: EnemyBrainSnapshot,
        directDirection: SIMD3<Float>,
        blocker: EnemyBodySnapshot?,
        previousFlankSide: Int?
    ) -> Int {
        if let previousFlankSide,
           previousFlankSide != 0 {
            return previousFlankSide < 0 ? -1 : 1
        }

        guard let blocker else {
            return enemy.id.uuidString.hashValue.isMultiple(of: 2) ? -1 : 1
        }

        let toBlocker = blocker.centerWorld - enemy.position

        let crossY =
            directDirection.x * toBlocker.z -
            directDirection.z * toBlocker.x

        if crossY > 0 {
            return -1
        }

        if crossY < 0 {
            return 1
        }

        return enemy.id.uuidString.hashValue.isMultiple(of: 2) ? -1 : 1
    }

    private static func lateralDirection(
        direct: SIMD3<Float>,
        side: Int
    ) -> SIMD3<Float> {
        let right = SIMD3<Float>(
            direct.z,
            0,
            -direct.x
        )

        return flatNormalize(
            right * Float(side < 0 ? -1 : 1),
            fallback: right
        )
    }

    private static func userMovedFromAttackAnchor(
        playerPosition: SIMD3<Float>,
        enemy: EnemyBrainSnapshot
    ) -> Bool {
        guard let anchor = enemy.attackAnchorUserPosition else {
            return false
        }

        return crowdDistanceXZ(
            playerPosition,
            anchor
        ) >= enemy.attackAnchorBreakDistanceMeters
    }

    private static func crowdDistanceXZ(
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>
    ) -> Float {
        let dx = a.x - b.x
        let dz = a.z - b.z
        return sqrt(dx * dx + dz * dz)
    }

    private static func yawForward(
        yawRadians: Float
    ) -> SIMD3<Float> {
        simd_quatf(
            angle: yawRadians,
            axis: SIMD3<Float>(0, 1, 0)
        ).act(
            SIMD3<Float>(0, 0, -1)
        )
    }

    private static func rotateFlat(
        _ vector: SIMD3<Float>,
        radians: Float
    ) -> SIMD3<Float> {
        guard abs(radians) > 0.0001 else {
            return vector
        }

        let c = cos(radians)
        let s = sin(radians)

        return flatNormalize(
            SIMD3<Float>(
                vector.x * c - vector.z * s,
                0,
                vector.x * s + vector.z * c
            ),
            fallback: vector
        )
    }

    private static func validDirection(
        _ direction: SIMD3<Float>?
    ) -> SIMD3<Float>? {
        guard let direction else {
            return nil
        }

        var flat = SIMD3<Float>(
            direction.x,
            0,
            direction.z
        )

        guard flat.isFiniteVector,
              simd_length_squared(flat) > 0.000001 else {
            return nil
        }

        flat = simd_normalize(flat)
        return flat
    }

    private static func flatNormalize(
        _ vector: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        var flat = SIMD3<Float>(
            vector.x,
            0,
            vector.z
        )

        if flat.isFiniteVector,
           simd_length_squared(flat) > 0.000001 {
            return simd_normalize(flat)
        }

        flat = SIMD3<Float>(
            fallback.x,
            0,
            fallback.z
        )

        guard flat.isFiniteVector,
              simd_length_squared(flat) > 0.000001 else {
            return SIMD3<Float>(0, 0, -1)
        }

        return simd_normalize(flat)
    }
}

private extension SIMD3 where Scalar == Float {
    var isFiniteVector: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
