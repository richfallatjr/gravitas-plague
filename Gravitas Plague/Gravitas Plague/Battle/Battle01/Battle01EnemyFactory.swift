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
        doorContext: TuringStoryDoorBattlePortalContext,
        battleInstanceID: UUID
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
        source.configureIncomingPunchPolicy(
            .storyGrandmaThreeX,
            storyBattleInstanceID: battleInstanceID
        )

        print("""
        [Battle01GrandmaHit] policy installed
          battleInstanceID: \(battleInstanceID.uuidString)
          enemyID: \(enemyID.uuidString)
          policy: storyGrandmaThreeX
          damageAcceptanceProbability: 0.33333333
          portalMirrorHasPolicy: false
        """)

        if source.rootEntity.parent == nil {
            sceneRoot.addChild(source.rootEntity)
        }
        let a1World = doorContext.zombieA1.position(relativeTo: nil)
        let a2World = doorContext.zombieA2.position(relativeTo: nil)
        let routeToDoor = PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(
                a2World.x - a1World.x,
                0,
                a2World.z - a1World.z
            ),
            fallback: SIMD3<Float>(0, 0, -1)
        )
        let initialForward = -routeToDoor
        let initialYawRadians = PhaseOneMath.yawRadiansForNegativeZForward(
            worldForward: initialForward
        )
        let authoredA1Orientation = doorContext.zombieA1.orientation(relativeTo: nil)

        source.rootEntity.setPosition(
            a1World,
            relativeTo: nil
        )
        source.rootEntity.setOrientation(
            simd_quatf(
                angle: initialYawRadians,
                axis: SIMD3<Float>(0, 1, 0)
            ),
            relativeTo: nil
        )
        source.lockRootToFloorY(
            a1World.y
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
          authoredA1Orientation: \(authoredA1Orientation)
          initialForward: \(initialForward)
          initialYawDegrees: \(initialYawRadians * 180 / .pi)
          pitchRollRemoved: true
          orientationBasis: opposite_a1_to_a2_route
        """)

        return Battle01PreparedEnemy(
            enemyID: enemyID,
            sourceController: source,
            sourceRoot: source.rootEntity,
            portalMirror: mirror
        )
    }
}
