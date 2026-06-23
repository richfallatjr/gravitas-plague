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
}

struct EnemyBrainFollowIntent: Sendable {
    let movementDirectionWorld: SIMD3<Float>
    let nextYawRadians: Float
    let distanceToUserXZ: Float
    let remainingSafeTravelMeters: Float
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

    func step(
        frame: FrameClockSnapshot,
        player: PlayerPoseSnapshot,
        enemies: [EnemyBrainSnapshot]
    ) -> HordeEnemyBrainCommands {
        let request = EnemyBrainBatchRequest(
            frame: frame,
            player: player,
            enemies: enemies
        )

        return step(request)
    }

    func step(
        _ request: EnemyBrainBatchRequest
    ) -> HordeEnemyBrainCommands {
        let commands = EnemyBrainDecisionEngine.step(
            frame: request.frame,
            player: request.player,
            enemies: request.enemies
        )

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
    }

    private func updateState(
        commands: [EnemyBrainCommand],
        liveEnemyIDs: Set<UUID>
    ) {
        lastFollowIntentByEnemyID = lastFollowIntentByEnemyID.filter {
            liveEnemyIDs.contains($0.key)
        }

        for command in commands {
            switch command {
            case .applyFollowIntent(let enemyID, let intent):
                lastFollowIntentByEnemyID[enemyID] = intent

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
    static func step(
        frame: FrameClockSnapshot,
        player: PlayerPoseSnapshot,
        enemies: [EnemyBrainSnapshot]
    ) -> [EnemyBrainCommand] {
        enemies.flatMap {
            commands(
                frame: frame,
                player: player,
                enemy: $0
            )
        }
    }

    private static func commands(
        frame: FrameClockSnapshot,
        player: PlayerPoseSnapshot,
        enemy: EnemyBrainSnapshot
    ) -> [EnemyBrainCommand] {
        guard !enemy.isDead,
              !enemy.isHitReacting else {
            return []
        }

        switch enemy.state {
        case .dead, .hitReaction:
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
                    distance: distance
                )
            }

            guard distance <= enemy.attackProximityMeters else {
                return followCommands(
                    frame: frame,
                    player: player,
                    enemy: enemy,
                    distance: distance
                )
            }

            return [
                .startAttack(
                    enemyID: enemy.id,
                    attackAnchorUserPosition: player.position
                )
            ]

        case .inactive:
            return []
        }
    }

    private static func followCommands(
        frame: FrameClockSnapshot,
        player: PlayerPoseSnapshot,
        enemy: EnemyBrainSnapshot,
        distance: Float
    ) -> [EnemyBrainCommand] {
        guard let intent = followIntent(
            frame: frame,
            player: player,
            enemy: enemy,
            distance: distance
        ) else {
            return []
        }

        return [
            .applyFollowIntent(
                enemyID: enemy.id,
                intent: intent
            )
        ]
    }

    private static func followIntent(
        frame: FrameClockSnapshot,
        player: PlayerPoseSnapshot,
        enemy: EnemyBrainSnapshot,
        distance: Float
    ) -> EnemyBrainFollowIntent? {
        let directToPlayer = flatNormalize(
            player.position - enemy.position,
            fallback: yawForward(
                yawRadians: enemy.yawRadians
            )
        )

        guard simd_length_squared(directToPlayer) > 0.000001 else {
            return nil
        }

        let movementDirection = rotateFlat(
            directToPlayer,
            radians: enemy.crowdSteerAngleRadians
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
            let maxStep = enemy.maxTurnRadiansPerSecond * frame.deltaTime
            let clampedStep = min(
                max(deltaYaw, -maxStep),
                maxStep
            )

            nextYaw = PhaseOneMath.normalizedAngleRadians(
                enemy.yawRadians + clampedStep
            )
        }

        return EnemyBrainFollowIntent(
            movementDirectionWorld: movementDirection,
            nextYawRadians: nextYaw,
            distanceToUserXZ: distance,
            remainingSafeTravelMeters: distance - enemy.attackProximityMeters
        )
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
        ) >= HordeCrowdSteeringSettings.userMoveBreakAttackMeters
    }

}
