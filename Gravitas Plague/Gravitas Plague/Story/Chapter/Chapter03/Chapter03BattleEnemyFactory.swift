import Foundation
import RealityKit
import simd

@MainActor
final class Chapter03BattleEnemyFactory {
    typealias PreparedCallback = @MainActor (UUID, JockRetargetTestController) -> Void

    private let sceneRoot: Entity
    private let onPrepared: PreparedCallback

    init(
        sceneRoot: Entity,
        onPrepared: @escaping PreparedCallback
    ) {
        self.sceneRoot = sceneRoot
        self.onPrepared = onPrepared
    }

    func prepareBiker(
        definition: Chapter03BattleDefinition,
        doorContext: TuringStoryDoorBattlePortalContext,
        battleInstanceID: UUID
    ) async throws -> ScriptedPortalPreparedEnemy {
        let attributes = try CharacterAttributeStore.shared.attributes(for: .biker)
        let hordeCapacity = attributes.horde.hitsToKill.random()
        let capacity = Chapter01DadBattleEnemyFactory.storyAcceptedHitCapacity(
            hordeCapacity: hordeCapacity,
            multiplier: definition.enemy.storyAcceptedHitCapacityMultiplier
        )
        return try await prepare(
            definition: definition,
            archetype: .biker,
            attributes: attributes,
            capacity: capacity,
            battleInstanceID: battleInstanceID,
            doorContext: doorContext,
            terminalDisposition: .playAuthoredDeath,
            sampledCapacityDescription: "horde=\(hordeCapacity) story=\(capacity)"
        )
    }

    func prepareMike(
        definition: Chapter03BattleDefinition,
        doorContext: TuringStoryDoorBattlePortalContext,
        battleInstanceID: UUID
    ) async throws -> ScriptedPortalPreparedEnemy {
        let attributes = try CharacterAttributeStore.shared.attributes(for: .neighbor)
        let dadAttributes = try CharacterAttributeStore.shared.attributes(for: .dad)
        let dadHordeCapacity = dadAttributes.horde.hitsToKill.random()
        let dadEquivalent = Chapter01DadBattleEnemyFactory.storyAcceptedHitCapacity(
            hordeCapacity: dadHordeCapacity,
            multiplier: definition.enemy.storyAcceptedHitCapacityMultiplier
        )
        let capacity = Self.mikeAcceptedHitCapacity(
            dadEquivalentCapacity: dadEquivalent,
            numerator: definition.enemy.acceptedCapacityNumerator,
            denominator: definition.enemy.acceptedCapacityDenominator
        )
        return try await prepare(
            definition: definition,
            archetype: .neighbor,
            attributes: attributes,
            capacity: capacity,
            battleInstanceID: battleInstanceID,
            doorContext: doorContext,
            terminalDisposition: .interceptAsNonlethalDefeat,
            sampledCapacityDescription:
                "dadHorde=\(dadHordeCapacity) dadEquivalent=\(dadEquivalent) mike=\(capacity)"
        )
    }

    nonisolated static func mikeAcceptedHitCapacity(
        dadEquivalentCapacity: Int,
        numerator: Int,
        denominator: Int
    ) -> Int {
        precondition(dadEquivalentCapacity > 0)
        precondition(numerator > 0 && denominator > 0)
        return (dadEquivalentCapacity * numerator + denominator - 1) / denominator
    }

    private func prepare(
        definition: Chapter03BattleDefinition,
        archetype: PlagueCharacterArchetype,
        attributes: CharacterAttributes,
        capacity: Int,
        battleInstanceID: UUID,
        doorContext: TuringStoryDoorBattlePortalContext,
        terminalDisposition: JockTerminalAcceptedDamageDisposition,
        sampledCapacityDescription: String
    ) async throws -> ScriptedPortalPreparedEnemy {
        guard attributes.characterID == definition.enemy.characterID,
              attributes.asset.usdz == definition.enemy.sourceAsset else {
            throw Chapter03Error.definitionInvalid(
                "Character asset does not match \(definition.enemy.characterID) attributes."
            )
        }

        let enemyID = UUID()
        let source = JockRetargetTestController()
        source.configureStoryBattleIdentity(
            id: enemyID,
            battleInstanceID: battleInstanceID,
            enemyTypeID: definition.enemy.storyEnemyID,
            archetype: archetype,
            hitsToKill: capacity,
            attributes: attributes
        )
        TuringMemoryBudgetProbe.log(label: "beforeChapter03BattleLoad.\(archetype.rawValue)")
        try await source.loadIfNeeded()
        TuringMemoryBudgetProbe.log(label: "afterChapter03BattleLoad.\(archetype.rawValue)")
        source.prepareFreshStoryBattleSpawn()
        source.configureIncomingPunchPolicy(
            .storyGrandmaThreeX,
            storyBattleInstanceID: battleInstanceID
        )
        source.configureTerminalAcceptedDamageDisposition(terminalDisposition)
        var required: Set<String> = ["idle_01", "turn_right_90", "unstable_walk_01"]
        if terminalDisposition == .playAuthoredDeath {
            required.formUnion(["dead_fall_forward_01", "dead_fall_backward_01"])
        }
        try source.requirePreparedAnimationIDs(required)

        if source.rootEntity.parent == nil {
            sceneRoot.addChild(source.rootEntity)
        }
        let a1 = doorContext.zombieA1.position(relativeTo: nil)
        let a2 = doorContext.zombieA2.position(relativeTo: nil)
        let route = PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(a2.x - a1.x, 0, a2.z - a1.z),
            fallback: SIMD3<Float>(0, 0, -1)
        )
        let initialForward = -route
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
        source.setExternalMotionDriven(true)
        source.setRootMotionEnabled(false)
        HordeGroundingOcclusionInstaller.installZombieCasters(
            on: source.rootEntity,
            enemyID: enemyID,
            characterID: attributes.characterID,
            reason: "Chapter03.\(archetype.rawValue).authoritativeSource"
        )
        onPrepared(enemyID, source)

        let mirror = try StoryPortalEnemyRenderMirrorAdapter(
            source: source,
            portalWorldRoot: doorContext.portalWorldRoot,
            portalPlaneEntity: doorContext.portalPlane
        )
        source.rootEntity.isEnabled = false

        print(
            "[Chapter03Battle] enemy prepared battleInstanceID=\(battleInstanceID.uuidString) " +
                "enemyID=\(enemyID.uuidString) character=\(attributes.characterID) " +
                "capacity={\(sampledCapacityDescription)} terminal=\(String(describing: terminalDisposition))"
        )
        return ScriptedPortalPreparedEnemy(
            enemyID: enemyID,
            sourceController: source,
            sourceRoot: source.rootEntity,
            portalMirror: mirror
        )
    }
}
