import Foundation
import RealityKit
import simd

@MainActor
final class HordeEnemyBodySeparationResolver {
    struct Settings {
        static let skinMeters: Float = 0.015
        static let maxCorrectionPerEnemyPerFrame: Float = 0.09
        static let solverIterations = 3
        static let tieDistanceEpsilon: Float = 0.05
    }

    private var lastCorrectionSummaryTime: TimeInterval = 0
    private var correctionsSinceSummary = 0
    private var maxCorrectionMagnitudeSinceSummary: Float = 0
    private var lastCorrectedEnemyID: UUID?
    private var lastCorrectedCharacterID: String?

    func resolve(
        enemies: [JockRetargetTestController],
        headsetPosition: SIMD3<Float>
    ) {
        let activeEnemies = enemies.filter {
            $0.enemyBodyCollisionParticipant &&
            !$0.isDeadForHordeCollision &&
            $0.bodyCollisionBox?.enabled == true
        }

        guard activeEnemies.count >= 2 else {
            return
        }

        for _ in 0..<Settings.solverIterations {
            let snapshots = activeEnemies.compactMap {
                HordeEnemyCollisionSnapshotBuilder.makeSnapshot(
                    controller: $0,
                    headsetPosition: headsetPosition
                )
            }

            var correctionsByEnemyID: [UUID: SIMD3<Float>] = [:]

            for i in snapshots.indices {
                for j in snapshots.indices where j > i {
                    let a = snapshots[i]
                    let b = snapshots[j]

                    guard let mtv = HordeEnemyBodySeparationMath.minimumTranslationVector(
                        a,
                        b
                    ) else {
                        continue
                    }

                    distributeCorrection(
                        mtv: mtv,
                        a: a,
                        b: b,
                        correctionsByEnemyID: &correctionsByEnemyID
                    )
                }
            }

            applyCorrections(
                correctionsByEnemyID,
                snapshots: snapshots
            )
        }
    }
}

private extension HordeEnemyBodySeparationResolver {
    func distributeCorrection(
        mtv: HordeEnemyBodySeparationMath.MTV,
        a: HordeEnemyCollisionSnapshot,
        b: HordeEnemyCollisionSnapshot,
        correctionsByEnemyID: inout [UUID: SIMD3<Float>]
    ) {
        let depth = mtv.depth + Settings.skinMeters

        let axis = SIMD3<Float>(
            mtv.axisXZ.x,
            0,
            mtv.axisXZ.y
        )

        let aAttacking = a.controller.isAttackOrCombatActiveForSeparation
        let bAttacking = b.controller.isAttackOrCombatActiveForSeparation

        if aAttacking && bAttacking {
            correctionsByEnemyID[
                a.enemyID,
                default: SIMD3<Float>(repeating: 0)
            ] += axis * (depth * 0.5)
            correctionsByEnemyID[
                b.enemyID,
                default: SIMD3<Float>(repeating: 0)
            ] -= axis * (depth * 0.5)
            return
        }

        if aAttacking && !bAttacking {
            correctionsByEnemyID[
                b.enemyID,
                default: SIMD3<Float>(repeating: 0)
            ] -= axis * depth
            return
        }

        if bAttacking && !aAttacking {
            correctionsByEnemyID[
                a.enemyID,
                default: SIMD3<Float>(repeating: 0)
            ] += axis * depth
            return
        }

        let lowerPriority = lowerPriorityEnemy(a, b)

        if lowerPriority.enemyID == a.enemyID {
            correctionsByEnemyID[
                a.enemyID,
                default: SIMD3<Float>(repeating: 0)
            ] += axis * depth
        } else {
            correctionsByEnemyID[
                b.enemyID,
                default: SIMD3<Float>(repeating: 0)
            ] -= axis * depth
        }
    }

    func lowerPriorityEnemy(
        _ a: HordeEnemyCollisionSnapshot,
        _ b: HordeEnemyCollisionSnapshot
    ) -> HordeEnemyCollisionSnapshot {
        let delta = a.distanceToHeadsetXZ - b.distanceToHeadsetXZ

        if delta > Settings.tieDistanceEpsilon {
            return a
        }

        if delta < -Settings.tieDistanceEpsilon {
            return b
        }

        return a.spawnIndex > b.spawnIndex ? a : b
    }

    func applyCorrections(
        _ corrections: [UUID: SIMD3<Float>],
        snapshots: [HordeEnemyCollisionSnapshot]
    ) {
        for snapshot in snapshots {
            guard let rawCorrection = corrections[snapshot.enemyID] else {
                continue
            }

            let correction = capLength(
                rawCorrection,
                maxLength: Settings.maxCorrectionPerEnemyPerFrame
            )

            guard simd_length(correction) > 0.0001 else {
                continue
            }

            let enemy = snapshot.controller
            let beforeAttackActive = enemy.isAttackOrCombatActiveForSeparation
            let beforeAnimationName = enemy.currentAnimationNameForSeparationDebug
            let current = enemy.rootEntity.position(relativeTo: nil)

            // IP slide is positional correction only. It must not change the
            // goal, target, locomotion direction, animation, or attack state.
            enemy.rootEntity.setPosition(
                current + correction,
                relativeTo: nil
            )

            #if DEBUG
            assertSeparationDidNotChangeBehavior(
                enemy: enemy,
                beforeAttackActive: beforeAttackActive,
                beforeAnimationName: beforeAnimationName
            )
            #endif

            recordCorrectionSummaryIfNeeded(
                enemyID: snapshot.enemyID,
                characterID: enemy.enemySeparationCharacterID,
                correction: correction
            )
        }
    }

    func recordCorrectionSummaryIfNeeded(
        enemyID: UUID,
        characterID: String,
        correction: SIMD3<Float>
    ) {
        correctionsSinceSummary += 1
        maxCorrectionMagnitudeSinceSummary = max(
            maxCorrectionMagnitudeSinceSummary,
            simd_length(correction)
        )
        lastCorrectedEnemyID = enemyID
        lastCorrectedCharacterID = characterID

        let now = TimingProfiler.now()

        guard now - lastCorrectionSummaryTime >= 1.0 else {
            return
        }

        lastCorrectionSummaryTime = now

        print(
            """
            [EnemySeparation] correction summary
              corrections: \(correctionsSinceSummary)
              lastEnemyID: \(lastCorrectedEnemyID?.uuidString ?? "nil")
              lastCharacterID: \(lastCorrectedCharacterID ?? "nil")
              maxCorrection: \(maxCorrectionMagnitudeSinceSummary)
              attackStateUnchanged: true
              animationUnchanged: true
              targetUnchanged: user
            """
        )

        correctionsSinceSummary = 0
        maxCorrectionMagnitudeSinceSummary = 0
        lastCorrectedEnemyID = nil
        lastCorrectedCharacterID = nil
    }

    func capLength(
        _ value: SIMD3<Float>,
        maxLength: Float
    ) -> SIMD3<Float> {
        let length = simd_length(value)

        guard length > maxLength,
              length > 0.00001 else {
            return value
        }

        return value / length * maxLength
    }

    #if DEBUG
    func assertSeparationDidNotChangeBehavior(
        enemy: JockRetargetTestController,
        beforeAttackActive: Bool,
        beforeAnimationName: String?
    ) {
        if beforeAttackActive != enemy.isAttackOrCombatActiveForSeparation {
            assertionFailure(
                """
                [EnemySeparation] ERROR separation changed attack state.
                Separation must be position-only.
                """
            )
        }

        if beforeAnimationName != enemy.currentAnimationNameForSeparationDebug {
            assertionFailure(
                """
                [EnemySeparation] ERROR separation changed animation state.
                Separation must be position-only.
                """
            )
        }
    }
    #endif
}
