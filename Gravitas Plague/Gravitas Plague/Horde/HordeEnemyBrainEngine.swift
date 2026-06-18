import Foundation
import simd

struct HordeEnemyBrainCommands: Sendable {
    let frameIndex: Int
    let commands: [EnemyBrainCommand]
}

enum EnemyBrainCommand: Sendable {
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
    func step(
        frame: FrameClockSnapshot,
        player: PlayerPoseSnapshot,
        enemies: [EnemyBrainSnapshot]
    ) -> HordeEnemyBrainCommands {
        let commands = EnemyBrainDecisionEngine.step(
            frame: frame,
            player: player,
            enemies: enemies
        )

        return HordeEnemyBrainCommands(
            frameIndex: frame.frameIndex,
            commands: commands
        )
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
        guard enemy.attackEnabled,
              !enemy.isDead,
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

            guard distance <= enemy.attackProximityMeters else {
                return []
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
