import Foundation
import RealityKit
import simd

@MainActor
final class Chapter01DadBattleEnemyFactory {
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
        definition: Chapter01DadFinalBattleDefinition,
        doorContext: TuringStoryDoorBattlePortalContext,
        battleInstanceID: UUID
    ) async throws -> ScriptedPortalPreparedEnemy {
        let attributes = try CharacterAttributeStore.shared.attributes(for: .dad)
        guard attributes.characterID == definition.enemy.characterID,
              attributes.asset.usdz == definition.enemy.sourceAsset else {
            throw Chapter01DadFinalBattleDefinitionStore.StoreError
                .invalidContract("Dad character asset does not match character attributes")
        }

        let enemyID = UUID()
        let hordeCapacity = attributes.horde.hitsToKill.random()
        let storyCapacity = Self.storyAcceptedHitCapacity(
            hordeCapacity: hordeCapacity,
            multiplier: definition.enemy.storyAcceptedHitCapacityMultiplier
        )
        let source = JockRetargetTestController()
        source.configureStoryBattleIdentity(
            id: enemyID,
            battleInstanceID: battleInstanceID,
            enemyTypeID: definition.enemy.storyEnemyID,
            archetype: .dad,
            hitsToKill: storyCapacity,
            attributes: attributes
        )
        TuringMemoryBudgetProbe.log(label: "beforeChapter01DadBattleLoad")
        try await source.loadIfNeeded()
        TuringMemoryBudgetProbe.log(label: "afterChapter01DadBattleLoad")
        source.prepareFreshStoryBattleSpawn()
        source.configureIncomingPunchPolicy(
            .storyGrandmaThreeX,
            storyBattleInstanceID: battleInstanceID
        )
        try source.requirePreparedAnimationIDs([
            definition.enemy.idleClipID,
            definition.enemy.turnClipID,
            definition.enemy.walkClipID,
            "dead_fall_forward_01",
            "dead_fall_backward_01"
        ])

        if source.rootEntity.parent == nil {
            sceneRoot.addChild(source.rootEntity)
        }
        let a1 = doorContext.zombieA1.position(relativeTo: nil)
        let a2 = doorContext.zombieA2.position(relativeTo: nil)
        let routeToDoor = PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(a2.x - a1.x, 0, a2.z - a1.z),
            fallback: SIMD3<Float>(0, 0, -1)
        )
        let initialForward = -routeToDoor
        let initialYaw = PhaseOneMath.yawRadiansForNegativeZForward(
            worldForward: initialForward
        )
        source.rootEntity.setPosition(a1, relativeTo: nil)
        source.rootEntity.setOrientation(
            simd_quatf(angle: initialYaw, axis: SIMD3<Float>(0, 1, 0)),
            relativeTo: nil
        )
        source.useAuthoredCharacterHeadingCorrection()
        source.lockRootToFloorY(a1.y)
        source.show()
        source.setCombatEnabled(false)
        source.setExternalMotionDriven(definition.enemy.externalMotionDriven)
        source.setRootMotionEnabled(definition.enemy.rootMotionEnabledDuringPath)

        HordeGroundingOcclusionInstaller.installZombieCasters(
            on: source.rootEntity,
            enemyID: enemyID,
            characterID: attributes.characterID,
            reason: "Chapter01DadBattle.authoritativeSource"
        )
        onPrepared(enemyID, source)

        let mirror = try StoryPortalEnemyRenderMirrorAdapter(
            source: source,
            portalWorldRoot: doorContext.portalWorldRoot,
            portalPlaneEntity: doorContext.portalPlane
        )
        source.rootEntity.isEnabled = false

        print("""
        [Chapter01DadBattle] Dad prepared
          battleInstanceID: \(battleInstanceID.uuidString)
          enemyID: \(enemyID.uuidString)
          characterID: \(attributes.characterID)
          asset: \(attributes.asset.usdz)
          hordeAcceptedHitCapacity: \(hordeCapacity)
          storyAcceptedHitCapacity: \(storyCapacity)
          incomingPunchPolicy: storyGrandmaThreeX
          a1World: \(a1)
          a2World: \(a2)
          initialForward: \(initialForward)
          initialYawDegrees: \(initialYaw * 180 / .pi)
          mirrorCollision: false
          mirrorAudio: false
          mirrorDamageAuthority: false
        """)

        return ScriptedPortalPreparedEnemy(
            enemyID: enemyID,
            sourceController: source,
            sourceRoot: source.rootEntity,
            portalMirror: mirror
        )
    }

    nonisolated static func storyAcceptedHitCapacity(
        hordeCapacity: Int,
        multiplier: Int
    ) -> Int {
        max(1, hordeCapacity) * max(1, multiplier)
    }
}
