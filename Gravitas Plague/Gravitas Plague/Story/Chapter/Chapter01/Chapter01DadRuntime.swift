import Foundation
import RealityKit

@MainActor
final class Chapter01DadRuntime {
    let chapterRunID: UUID
    let context: TuringStoryWindowCinematicContext
    let lease: Chapter01DadRuntimeLease

    var controller: JockRetargetTestController? {
        lease.controller
    }

    init(
        chapterRunID: UUID,
        context: TuringStoryWindowCinematicContext,
        lease: Chapter01DadRuntimeLease
    ) {
        self.chapterRunID = chapterRunID
        self.context = context
        self.lease = lease
    }
}

@MainActor
enum Chapter01DadRuntimeFactory {
    static func prepare(
        chapterRunID: UUID,
        context: TuringStoryWindowCinematicContext,
        heavyRuntimeRegistry: StoryHeavyRuntimeRegistry
    ) async throws -> Chapter01DadRuntime {
        let attributes = try CharacterAttributeStore.shared.attributes(for: .dad)
        let controller = JockRetargetTestController()
        controller.configureStoryBattleIdentity(
            id: UUID(),
            battleInstanceID: chapterRunID,
            enemyTypeID: "chapter01_dad_window",
            archetype: .dad,
            hitsToKill: 1,
            attributes: attributes
        )
        try await controller.loadIfNeeded()
        controller.prepareFreshStoryBattleSpawn()
        try controller.requirePreparedAnimationIDs(Set([
            "idle_01",
            "unstable_walk_01",
            "turn_left_90",
            "turn_right_90"
        ]))
        controller.setCombatEnabled(false)
        controller.setPlayerAttackEnabled(false)
        controller.setExternalMotionDriven(true)
        controller.setRootMotionEnabled(false)
        controller.onPunchHit = nil
        controller.onCharacterDamageHit = nil
        controller.onCharacterDeath = nil
        controller.onPlayerDamaged = nil
        controller.onAttackStarted = nil

        stripInteraction(from: controller.rootEntity)
        context.portalWorldRoot.addChild(controller.rootEntity)
        controller.updateGroundingProfileFromLoadedEntityIfNeeded()
        setController(
            controller,
            at: context.entryAnchor,
            relativeTo: context.portalWorldRoot
        )
        controller.show()

        let corpsePresenter = BattleCorpsePresentationController(
            storyRoot: context.portalWorldRoot
        )
        let lease = Chapter01DadRuntimeLease(
            chapterRunID: chapterRunID,
            controller: controller,
            corpsePresenter: corpsePresenter,
            heavyRuntimeRegistry: heavyRuntimeRegistry
        )
        await heavyRuntimeRegistry.register(.dad(chapterRunID))
        print(
            "[Chapter01Dad] runtime prepared chapterRunID=\(chapterRunID.uuidString) coordinateSpace=\(context.portalWorldRoot.name)"
        )
        return Chapter01DadRuntime(
            chapterRunID: chapterRunID,
            context: context,
            lease: lease
        )
    }

    static func setController(
        _ controller: JockRetargetTestController,
        at anchor: Entity,
        relativeTo coordinateSpace: Entity
    ) {
        let anchorTransform = anchor.transformMatrix(relativeTo: coordinateSpace)
        controller.rootEntity.setTransformMatrix(
            anchorTransform,
            relativeTo: coordinateSpace
        )
        let floorY = anchor.position(relativeTo: coordinateSpace).y
        var position = controller.rootEntity.position(relativeTo: coordinateSpace)
        position.y = controller.rootYForFloorY(floorY)
        controller.rootEntity.setPosition(position, relativeTo: coordinateSpace)
    }

    private static func stripInteraction(from entity: Entity) {
        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(CollisionComponent.self)
        for child in entity.children {
            stripInteraction(from: child)
        }
    }
}
