import Foundation
import RealityKit
import simd

@MainActor
struct Battle01PreparedEnemy {
    let enemyID: UUID
    let sourceController: JockRetargetTestController
    let sourceRoot: Entity
    let portalMirror: StoryPortalEnemyRenderMirrorAdapter
}

@MainActor
final class Battle01EnemyFactory {
    typealias PreparedCallback = @MainActor (
        UUID,
        JockRetargetTestController
    ) -> Void

    private let sceneRoot: Entity
    private let onPrepared: PreparedCallback

    init(
        sceneRoot: Entity,
        onPrepared: @escaping PreparedCallback
    ) {
        self.sceneRoot = sceneRoot
        self.onPrepared = onPrepared
    }

    func prepare(
        definition: Battle01Definition,
        doorContext: TuringStoryDoorBattlePortalContext
    ) async throws -> Battle01PreparedEnemy {
        let attributes = try CharacterAttributeStore.shared.attributes(for: .grandma)
        guard attributes.asset.usdz == definition.enemy.sourceAsset else {
            throw Battle01DefinitionStore.StoreError.invalidContract(
                "Grandma source asset mismatch: \(attributes.asset.usdz)"
            )
        }

        let enemyID = UUID()
        let source = JockRetargetTestController()
        source.configureStoryBattleIdentity(
            id: enemyID,
            archetype: .grandma,
            hitsToKill: attributes.horde.hitsToKill.random(),
            attributes: attributes
        )
        try await source.loadIfNeeded()
        source.prepareFreshStoryBattleSpawn()

        if source.rootEntity.parent == nil {
            sceneRoot.addChild(source.rootEntity)
        }
        source.rootEntity.setPosition(
            doorContext.zombieA1.position(relativeTo: nil),
            relativeTo: nil
        )
        source.rootEntity.setOrientation(
            doorContext.zombieA1.orientation(relativeTo: nil),
            relativeTo: nil
        )
        source.lockRootToFloorY(
            doorContext.zombieA1.position(relativeTo: nil).y
        )
        source.show()
        source.setCombatEnabled(false)
        source.setExternalMotionDriven(true)
        source.setRootMotionEnabled(false)

        HordeGroundingOcclusionInstaller.installZombieCasters(
            on: source.rootEntity,
            enemyID: enemyID,
            characterID: attributes.characterID,
            reason: "Battle01.authoritativeStoryEnemy"
        )
        onPrepared(enemyID, source)

        let mirror = try StoryPortalEnemyRenderMirrorAdapter(
            source: source,
            portalWorldRoot: doorContext.portalWorldRoot,
            portalPlaneEntity: doorContext.portalPlane
        )
        source.rootEntity.isEnabled = false

        print("""
        [Battle01] source prepared
          enemyID: \(enemyID.uuidString)
          characterID: \(attributes.characterID)
          asset: \(attributes.asset.usdz)
          additionalScaleApplied: false
          sourceVisible: false
          mirrorID: \(mirror.id.uuidString)
          secondAnimationClock: false
        """)

        return Battle01PreparedEnemy(
            enemyID: enemyID,
            sourceController: source,
            sourceRoot: source.rootEntity,
            portalMirror: mirror
        )
    }
}
