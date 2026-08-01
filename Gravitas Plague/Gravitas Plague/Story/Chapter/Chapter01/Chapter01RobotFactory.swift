import Foundation
import RealityKit
import simd

@MainActor
final class Chapter01RobotFactory {
    private let sceneRoot: Entity
    private let enemyRegistry: BattleEnemyRuntimeRegistry
    private let corpsePresenter: BattleCorpsePresentationController
    private let onPrepared: @MainActor (UUID, JockRetargetTestController) -> Void

    init(
        sceneRoot: Entity,
        enemyRegistry: BattleEnemyRuntimeRegistry,
        corpsePresenter: BattleCorpsePresentationController,
        onPrepared: @escaping @MainActor (UUID, JockRetargetTestController) -> Void = { _, _ in }
    ) {
        self.sceneRoot = sceneRoot
        self.enemyRegistry = enemyRegistry
        self.corpsePresenter = corpsePresenter
        self.onPrepared = onPrepared
    }

    func prepare(
        encounterID: UUID,
        definition: Chapter01RobotDefinition,
        doorContext: Chapter01RobotDoorContext
    ) async throws -> Chapter01RobotRuntime {
        try definition.validate()
        let attributes = try CharacterAttributeStore.shared.attributes(for: .robot)
        guard attributes.asset.usdz == definition.characterResource else {
            throw Chapter01RobotError.invalidDefinition(
                "Robot source asset mismatch: \(attributes.asset.usdz)"
            )
        }

        let enemyID = UUID()
        let acceptedHitsToDestroy = Int.random(
            in: definition.combat.acceptedPlayerHitsToDestroyMinimum ...
                definition.combat.acceptedPlayerHitsToDestroyMaximum
        )
        let controller = JockRetargetTestController()
        controller.configureStoryBattleIdentity(
            id: enemyID,
            battleInstanceID: encounterID,
            enemyTypeID: "gravitas_robot",
            archetype: .robot,
            hitsToKill: acceptedHitsToDestroy,
            attributes: attributes
        )

        TuringMemoryBudgetProbe.log(label: "beforeChapter01RobotLoad")
        try await controller.loadIfNeeded()
        TuringMemoryBudgetProbe.log(label: "afterChapter01RobotLoad")
        var portalMirror: StoryPortalEnemyRenderMirrorAdapter?
        var registered = false

        do {
            controller.prepareFreshStoryBattleSpawn()
            try controller.requirePreparedAnimationIDs(definition.requiredAnimationIDs)
            controller.configureIncomingPunchPolicy(
                .storyRobotTenPercent,
                storyBattleInstanceID: encounterID,
                damageRoller: JockProbabilityHeadPunchDamageRoller(
                    acceptanceProbability: definition.combat.incomingPlayerHitAcceptanceProbability
                )
            )
            controller.setCombatEnabled(false)
            controller.setExternalMotionDriven(true)
            controller.setRootMotionEnabled(false)
            controller.setupCharacterAudioEmitterFromAttributes()

            if controller.rootEntity.parent == nil {
                sceneRoot.addChild(controller.rootEntity)
            }
            let start = doorContext.robotDoorThreshold.position(relativeTo: nil)
            let mid = doorContext.robotExteriorMid.position(relativeTo: nil)
            let forward = PhaseOneMath.normalizedOrFallback(
                SIMD3<Float>(start.x - mid.x, 0, start.z - mid.z),
                fallback: SIMD3<Float>(0, 0, -1)
            )
            controller.rootEntity.setPosition(start, relativeTo: nil)
            controller.rootEntity.setOrientation(
                simd_quatf(from: SIMD3<Float>(0, 0, -1), to: forward),
                relativeTo: nil
            )
            controller.lockRootToFloorY(start.y)
            controller.show()

            let mirror = try StoryPortalEnemyRenderMirrorAdapter(
                source: controller,
                portalWorldRoot: doorContext.portalWorldRoot,
                portalPlaneEntity: doorContext.portalPlane,
                direction: .portalToRoom
            )
            portalMirror = mirror
            controller.rootEntity.isEnabled = false

            guard let emitter = controller.characterAudioEmitter else {
                throw Chapter01RobotError.audioEndpointMissing
            }
            let identity = controller.battleRuntimeIdentity
            let lease = BattleEnemyRuntimeLease(
                identity: identity,
                controller: controller,
                portalMirror: mirror
            )
            try enemyRegistry.register(lease)
            registered = true
            Chapter01RobotAudioRoute.install(on: emitter)
            onPrepared(enemyID, controller)

            print("""
            [Chapter01Robot] runtime prepared
              encounterID: \(encounterID.uuidString)
              enemyID: \(enemyID.uuidString)
              asset: \(attributes.asset.usdz)
              acceptedHitsToDestroy: \(acceptedHitsToDestroy)
              incomingHitAcceptanceProbability: \(definition.combat.incomingPlayerHitAcceptanceProbability)
              hordeConfigurationChanged: false
              initialAnchor: \(doorContext.robotDoorThreshold.name)
              initialState: idleAtDoorThreshold
              sourceVisible: false
              mirrorID: \(mirror.id.uuidString)
            """)

            return Chapter01RobotRuntime(
                identity: identity,
                controller: controller,
                roomRoot: controller.rootEntity,
                mirror: mirror,
                speechEmitter: emitter
            )
        } catch {
            if registered,
               let lease = enemyRegistry.take(
                   battleInstanceID: encounterID,
                   enemyID: enemyID
               ) {
                _ = try? await lease.release(
                    reason: .battleCancelled,
                    retentionPolicy: .remove,
                    corpsePresenter: corpsePresenter
                )
            } else {
                portalMirror?.removeAndRelease(reason: "robotPreparationFailed")
                _ = try? await controller.releaseBattleRuntime(
                    reason: .battleCancelled,
                    retentionPolicy: .remove,
                    corpsePresenter: corpsePresenter
                )
            }
            TuringMemoryBudgetProbe.log(label: "afterChapter01RobotLoadFailureRelease")
            throw error
        }
    }
}
