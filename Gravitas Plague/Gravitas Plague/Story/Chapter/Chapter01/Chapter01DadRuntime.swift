import Foundation
import RealityKit
import simd

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
        controller.useAuthoredCharacterHeadingCorrection()
        let heading = try controller.scriptedCharacterHeadingSnapshot()
        guard abs(heading.baseVisualCorrectionDegrees - 180) < 0.001,
              abs(heading.additiveVisualCorrectionDegrees) < 0.001,
              abs(heading.effectiveVisualCorrectionDegrees - 180) < 0.001 else {
            throw Chapter01Error.openingResourceUnavailable(
                "Dad heading correction must be base=180, additive=0, effective=180."
            )
        }
        print(
            """
            [Chapter01DadHeading] runtime correction
              characterID: dad
              renderedForwardSource: Head->headfront
              logicalRootForwardAxis: -z
              baseVisualCorrectionDegrees: \(heading.baseVisualCorrectionDegrees)
              additiveVisualCorrectionDegrees: \(heading.additiveVisualCorrectionDegrees)
              effectiveVisualCorrectionDegrees: \(heading.effectiveVisualCorrectionDegrees)
            """
        )
        controller.onPunchHit = nil
        controller.onCharacterDamageHit = nil
        controller.onCharacterDeath = nil
        controller.onPlayerDamaged = nil
        controller.onAttackStarted = nil

        stripInteraction(from: controller.rootEntity)
        context.portalWorldRoot.addChild(controller.rootEntity)
        controller.updateGroundingProfileFromLoadedEntityIfNeeded()
        installWorldPose(
            controller,
            floorPosition: context.route.entryWorldPosition,
            orientation: context.route.entryWalkWorldOrientation
        )
        // Spawn preparation enables the root before an animation owns the rig.
        // Keep it hidden until the entry walk has actually been submitted.
        controller.rootEntity.isEnabled = false

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
            "[Chapter01Dad] runtime prepared hidden=true chapterRunID=\(chapterRunID.uuidString) coordinateSpace=\(context.portalWorldRoot.name)"
        )
        return Chapter01DadRuntime(
            chapterRunID: chapterRunID,
            context: context,
            lease: lease
        )
    }

    static func installWorldPose(
        _ controller: JockRetargetTestController,
        floorPosition: SIMD3<Float>,
        orientation: simd_quatf,
        log: Bool = true
    ) {
        var position = floorPosition
        position.y = controller.rootYForFloorY(floorPosition.y)
        controller.rootEntity.setPosition(position, relativeTo: nil)
        controller.rootEntity.setOrientation(
            orientation,
            relativeTo: nil
        )

        if log {
            print(
                """
                [Chapter01Dad] runtime reset from fresh window world context
                  worldPosition: \(position)
                  worldOrientation: \(orientation.vector)
                """
            )
        }
    }

    private static func stripInteraction(from entity: Entity) {
        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(CollisionComponent.self)
        for child in entity.children {
            stripInteraction(from: child)
        }
    }
}
