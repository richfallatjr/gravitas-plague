import Foundation
import RealityKit
import simd

struct HordeEnemyCollisionSnapshot: Sendable {
    let enemyID: UUID
    let spawnIndex: Int
    let characterID: String
    let isAttacking: Bool
    let isDead: Bool

    let centerWorld: SIMD3<Float>

    let rightXZ: SIMD2<Float>
    let forwardXZ: SIMD2<Float>

    let halfWidth: Float
    let halfDepth: Float

    let minY: Float
    let maxY: Float

    let distanceToHeadsetXZ: Float
}

@MainActor
enum HordeEnemyCollisionSnapshotBuilder {
    private static var loggedSimplifiedBodyBoxSnapshotIDs = Set<UUID>()

    static func makeSnapshot(
        controller: JockRetargetTestController,
        headsetPosition: SIMD3<Float>
    ) -> HordeEnemyCollisionSnapshot? {
        guard controller.enemyBodyCollisionEnabled,
              controller.enemyBodyCollisionParticipant,
              controller.enemyCollisionState != .dead,
              !controller.isDeadForHordeCollision,
              let box = controller.bodyCollisionBox,
              box.enabled else {
            return nil
        }

        let enemyID = controller.hordeBenchmarkID
        let matrix = box.root.transformMatrix(relativeTo: nil)

        let center = SIMD3<Float>(
            matrix.columns.3.x,
            matrix.columns.3.y,
            matrix.columns.3.z
        )

        let rootMatrix = controller.rootEntity.transformMatrix(relativeTo: nil)

        let right = normalizeSafe2(
            SIMD2<Float>(
                rootMatrix.columns.0.x,
                rootMatrix.columns.0.z
            ),
            fallback: SIMD2<Float>(1, 0)
        )

        let forward = normalizeSafe2(
            SIMD2<Float>(
                rootMatrix.columns.2.x,
                rootMatrix.columns.2.z
            ),
            fallback: SIMD2<Float>(0, 1)
        )

        let halfSize = box.sizeMeters * 0.5

        let headsetXZ = SIMD2<Float>(
            headsetPosition.x,
            headsetPosition.z
        )

        let centerXZ = SIMD2<Float>(
            center.x,
            center.z
        )
        let distanceToHeadset = simd_length(centerXZ - headsetXZ)

        logSimplifiedBodyBoxSnapshotIfNeeded(
            enemyID: enemyID,
            characterID: controller.enemySeparationCharacterID,
            halfSize: halfSize,
            sizeMeters: box.sizeMeters
        )

        return HordeEnemyCollisionSnapshot(
            enemyID: enemyID,
            spawnIndex: controller.hordeSpawnIndex,
            characterID: controller.enemySeparationCharacterID,
            isAttacking: controller.isAttackOrCombatActiveForSeparation,
            isDead: controller.isDeadForHordeCollision,
            centerWorld: center,
            rightXZ: right,
            forwardXZ: forward,
            halfWidth: halfSize.x,
            halfDepth: halfSize.z,
            minY: center.y - halfSize.y,
            maxY: center.y + halfSize.y,
            distanceToHeadsetXZ: distanceToHeadset
        )
    }

    private static func logSimplifiedBodyBoxSnapshotIfNeeded(
        enemyID: UUID,
        characterID: String,
        halfSize: SIMD3<Float>,
        sizeMeters: SIMD3<Float>
    ) {
        guard RuntimeDiagnostics.hordeRuntimeSummariesEnabled,
              !loggedSimplifiedBodyBoxSnapshotIDs.contains(enemyID) else {
            return
        }

        loggedSimplifiedBodyBoxSnapshotIDs.insert(enemyID)

        print(
            """
            [CrowdBlocker] snapshot built from simplified body box
              enemyID: \(enemyID.uuidString)
              characterID: \(characterID)
              halfWidth: \(halfSize.x)
              halfDepth: \(halfSize.z)
              height: \(sizeMeters.y)
              source: character_attributes.body_collision
              fullGeometryUsed: false
            """
        )
    }
}
