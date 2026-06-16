import RealityKit
import simd
import UIKit

enum HordeEnemyCollisionSettings {
    static let clearDelay: Float = 0.20
    static let minBlockedTime: Float = 0.15
    static let distanceTieEpsilon: Float = 0.05
}

@MainActor
final class HordeEnemyCollisionCoordinator {
    var debugVisible = false {
        didSet {
            print("[EnemyCollision] debugVisible changed \(debugVisible)")
        }
    }

    private var debugLines: [Entity] = []
    private var debugLabels: [Entity] = []
    private var debugSummaryTimer: Float = 0

    func update(
        deltaTime: Float,
        headsetPosition: SIMD3<Float>,
        enemies: [JockRetargetTestController],
        sceneRoot: Entity
    ) {
        let livingEnemies = enemies.filter {
            $0.enemyBodyCollisionEnabled &&
            $0.enemyBodyCollisionParticipant &&
            $0.enemyCollisionState != .dead &&
            !$0.isDeadForHordeCollision
        }

        prepareEnemiesForCollisionPass(
            allEnemies: enemies
        )

        let snapshots = livingEnemies.compactMap {
            HordeEnemyCollisionSnapshotBuilder.makeSnapshot(
                controller: $0,
                headsetPosition: headsetPosition
            )
        }

        for i in snapshots.indices {
            for j in snapshots.indices where j > i {
                let a = snapshots[i]
                let b = snapshots[j]

                guard HordeEnemyCollisionMath.boxesIntersect(a, b) else {
                    continue
                }

                if HordeEnemyCollisionMath.shouldAStopBehindB(
                    a: a,
                    b: b,
                    tieEpsilon: HordeEnemyCollisionSettings.distanceTieEpsilon
                ) {
                    markBlocked(
                        blocked: a.controller,
                        blockerID: b.enemyID
                    )
                } else if HordeEnemyCollisionMath.shouldAStopBehindB(
                    a: b,
                    b: a,
                    tieEpsilon: HordeEnemyCollisionSettings.distanceTieEpsilon
                ) {
                    markBlocked(
                        blocked: b.controller,
                        blockerID: a.enemyID
                    )
                }
            }
        }

        applyCollisionStates(
            enemies: livingEnemies,
            deltaTime: deltaTime
        )

        updateDebug(
            sceneRoot: sceneRoot,
            snapshots: snapshots,
            enemies: enemies
        )

        logDebugSummaryIfNeeded(
            deltaTime: deltaTime,
            enemies: enemies,
            snapshotCount: snapshots.count
        )

        #if DEBUG
        validateDebugInvariants(
            enemies: enemies
        )
        #endif
    }
}

private extension HordeEnemyCollisionCoordinator {
    func prepareEnemiesForCollisionPass(
        allEnemies: [JockRetargetTestController]
    ) {
        for enemy in allEnemies {
            if enemy.isDeadForHordeCollision {
                enemy.enemyCollisionState = .dead
                enemy.enemyCollisionBlockedThisFrame = false
                enemy.enemyCollisionBlockedByIDs.removeAll()
                enemy.bodyCollisionBox?.setEnabled(false)
                continue
            }

            guard enemy.enemyBodyCollisionEnabled,
                  enemy.enemyBodyCollisionParticipant else {
                enemy.bodyCollisionBox?.setEnabled(false)
                continue
            }

            enemy.bodyCollisionBox?.setEnabled(true)
            enemy.enemyCollisionBlockedThisFrame = false
            enemy.enemyCollisionBlockedByIDs.removeAll()
        }
    }

    func markBlocked(
        blocked enemy: JockRetargetTestController,
        blockerID: UUID
    ) {
        enemy.enemyCollisionBlockedThisFrame = true
        enemy.enemyCollisionBlockedByIDs.insert(blockerID)
    }

    func applyCollisionStates(
        enemies: [JockRetargetTestController],
        deltaTime: Float
    ) {
        for enemy in enemies {
            if enemy.enemyCollisionBlockedThisFrame {
                enemy.enemyCollisionClearTimer = 0

                if enemy.enemyCollisionState != .blockedIdle {
                    enemy.enterEnemyBlockedIdle()
                } else {
                    enemy.enemyCollisionBlockedTimer += deltaTime
                }
            } else if enemy.enemyCollisionState == .blockedIdle {
                enemy.enemyCollisionClearTimer += deltaTime
                enemy.enemyCollisionBlockedTimer += deltaTime

                let canExit =
                    enemy.enemyCollisionClearTimer >= HordeEnemyCollisionSettings.clearDelay &&
                    enemy.enemyCollisionBlockedTimer >= HordeEnemyCollisionSettings.minBlockedTime

                if canExit {
                    enemy.exitEnemyBlockedIdle()
                }
            }
        }
    }

    func updateDebug(
        sceneRoot: Entity,
        snapshots: [HordeEnemyCollisionSnapshot],
        enemies: [JockRetargetTestController]
    ) {
        for enemy in enemies {
            enemy.bodyCollisionBox?.setDebugVisible(
                debugVisible,
                state: enemy.enemyCollisionState
            )
        }

        clearDebugLinesAndLabels()

        guard debugVisible else {
            return
        }

        for snapshot in snapshots {
            addDebugLabel(
                sceneRoot: sceneRoot,
                text: "\(snapshot.controller.enemyCollisionState.rawValue)\n\(String(format: "%.2fm", snapshot.distanceToHeadsetXZ))",
                position: snapshot.centerWorld +
                    SIMD3<Float>(
                        0,
                        snapshot.maxY - snapshot.centerWorld.y + 0.22,
                        0
                    )
            )

            for blockerID in snapshot.controller.enemyCollisionBlockedByIDs {
                guard let blocker = snapshots.first(where: { $0.enemyID == blockerID }) else {
                    continue
                }

                addDebugLine(
                    sceneRoot: sceneRoot,
                    from: snapshot.centerWorld,
                    to: blocker.centerWorld,
                    color: .yellow
                )
            }
        }
    }

    func clearDebugLinesAndLabels() {
        for line in debugLines {
            line.removeFromParent()
        }

        for label in debugLabels {
            label.removeFromParent()
        }

        debugLines.removeAll()
        debugLabels.removeAll()
    }

    func addDebugLine(
        sceneRoot: Entity,
        from a: SIMD3<Float>,
        to b: SIMD3<Float>,
        color: UIColor
    ) {
        let delta = b - a
        let length = simd_length(delta)

        guard length > 0.001 else {
            return
        }

        let mesh = MeshResource.generateCylinder(
            height: length,
            radius: 0.008
        )

        var material = SimpleMaterial(
            color: color.withAlphaComponent(0.85),
            isMetallic: false
        )
        material.color = .init(tint: color.withAlphaComponent(0.85))

        let entity = ModelEntity(
            mesh: mesh,
            materials: [material]
        )

        entity.position = (a + b) * 0.5
        entity.orientation = simd_quatf(
            from: SIMD3<Float>(0, 1, 0),
            to: simd_normalize(delta)
        )
        entity.name = "EnemyCollisionDebugBlockerLine"

        sceneRoot.addChild(entity)
        debugLines.append(entity)
    }

    func addDebugLabel(
        sceneRoot: Entity,
        text: String,
        position: SIMD3<Float>
    ) {
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.001,
            font: .systemFont(ofSize: 0.06),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )

        var material = UnlitMaterial()
        material.color = .init(tint: UIColor.white.withAlphaComponent(0.9))

        let label = ModelEntity(
            mesh: mesh,
            materials: [material]
        )

        label.name = "EnemyCollisionDebugLabel"
        label.position = position

        sceneRoot.addChild(label)
        debugLabels.append(label)
    }

    func logDebugSummaryIfNeeded(
        deltaTime: Float,
        enemies: [JockRetargetTestController],
        snapshotCount: Int
    ) {
        guard debugVisible else {
            debugSummaryTimer = 0
            return
        }

        debugSummaryTimer += deltaTime

        guard debugSummaryTimer >= 1.0 else {
            return
        }

        debugSummaryTimer = 0

        let blocked = enemies.filter {
            $0.enemyCollisionState == .blockedIdle
        }.count

        let moving = enemies.filter {
            $0.enemyCollisionState == .moving
        }.count

        print(
            """
            [EnemyCollision] summary
              moving: \(moving)
              blocked: \(blocked)
              snapshots: \(snapshotCount)
            """
        )
    }

    #if DEBUG
    func validateDebugInvariants(
        enemies: [JockRetargetTestController]
    ) {
        for enemy in enemies {
            if enemy.enemyCollisionState == .dead,
               enemy.bodyCollisionBox?.enabled == true {
                assertionFailure("[EnemyCollision] dead enemy has enabled collision box")
            }

            if enemy.enemyCollisionState == .blockedIdle,
               enemy.hordeLocomotionBlockedByEnemyCollision == false {
                assertionFailure("[EnemyCollision] blocked enemy locomotion still enabled")
            }
        }
    }
    #endif
}
