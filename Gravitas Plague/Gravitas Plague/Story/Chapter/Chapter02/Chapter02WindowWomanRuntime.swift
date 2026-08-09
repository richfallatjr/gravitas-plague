import Foundation
import RealityKit
import simd

@MainActor
final class Chapter02WomanRuntimeLease {
    let chapterRunID: UUID
    private(set) var tier: Chapter02WomanRuntimeTier = .windowPresentation
    private(set) var controller: JockRetargetTestController?

    private let corpsePresenter: BattleCorpsePresentationController
    private let heavyRuntimeRegistry: StoryHeavyRuntimeRegistry

    init(
        chapterRunID: UUID,
        controller: JockRetargetTestController,
        corpsePresenter: BattleCorpsePresentationController,
        heavyRuntimeRegistry: StoryHeavyRuntimeRegistry
    ) {
        self.chapterRunID = chapterRunID
        self.controller = controller
        self.corpsePresenter = corpsePresenter
        self.heavyRuntimeRegistry = heavyRuntimeRegistry
    }

    func markPortalIntro() throws {
        guard tier == .windowPresentation, controller != nil else {
            throw Chapter02Error.invalidRuntimeTransfer(
                "portal intro requires the live window-presentation source"
            )
        }
        tier = .portalIntro
    }

    func prepareCombatIdentity(
        battleInstanceID: UUID
    ) throws -> JockRetargetTestController {
        guard tier == .portalIntro, let controller else {
            throw Chapter02Error.invalidRuntimeTransfer(
                "combat requires the portal-intro source"
            )
        }
        let attributes = try CharacterAttributeStore.shared.attributes(for: .spouse)
        let hordeCapacity = attributes.horde.hitsToKill.random()
        controller.configureStoryBattleIdentity(
            id: UUID(),
            battleInstanceID: battleInstanceID,
            enemyTypeID: "chapter02_spouse_story",
            archetype: .spouse,
            hitsToKill: Battle01EnemyFactory.storyHitsToKill(
                currentHitsToKill: hordeCapacity
            ),
            attributes: attributes
        )
        controller.prepareFreshStoryBattleSpawn()
        controller.configureIncomingPunchPolicy(
            .storyGrandmaThreeX,
            storyBattleInstanceID: battleInstanceID
        )
        tier = .combat
        print(
            "[Chapter02Woman] existing runtime upgraded tier=combat " +
                "battleInstanceID=\(battleInstanceID.uuidString) secondUSDZImport=false"
        )
        return controller
    }

    func relinquishControllerToBattleRegistry()
        throws -> JockRetargetTestController {
        guard tier == .combat, let controller else {
            throw Chapter02Error.invalidRuntimeTransfer(
                "battle registry requires the combat source"
            )
        }
        self.controller = nil
        return controller
    }

    func markReleased() async {
        tier = .released
        controller = nil
        await heavyRuntimeRegistry.remove(.chapter02Woman(chapterRunID))
    }

    func release(reason: BattleEnemyReleaseReason) async throws
        -> BattleEnemyRuntimeReleaseResult? {
        guard let controller else {
            await markReleased()
            return nil
        }
        controller.cancelScriptedClipCompletion()
        controller.stopScriptedLocomotion(reason: reason.rawValue)
        let result = try await controller.releaseBattleRuntime(
            reason: reason,
            retentionPolicy: .remove,
            corpsePresenter: corpsePresenter
        )
        await markReleased()
        return result
    }
}

@MainActor
final class Chapter02WindowWomanRuntime {
    let chapterRunID: UUID
    let context: TuringStoryWindowCinematicContext
    let lease: Chapter02WomanRuntimeLease

    var controller: JockRetargetTestController? { lease.controller }

    init(
        chapterRunID: UUID,
        context: TuringStoryWindowCinematicContext,
        lease: Chapter02WomanRuntimeLease
    ) {
        self.chapterRunID = chapterRunID
        self.context = context
        self.lease = lease
    }
}

@MainActor
enum Chapter02WindowWomanRuntimeFactory {
    static let presentationClipIDs: Set<String> = [
        "idle_01",
        "unstable_walk_01",
        "turn_left_90",
        "turn_right_90",
        "charged-slash-left",
        "charged-slash-right",
        "left_hook_01",
        "right_hook_01"
    ]

    static func prepare(
        chapterRunID: UUID,
        context: TuringStoryWindowCinematicContext,
        sceneRoot: Entity,
        heavyRuntimeRegistry: StoryHeavyRuntimeRegistry = .shared
    ) async throws -> Chapter02WindowWomanRuntime {
        let attributes = try CharacterAttributeStore.shared.attributes(for: .spouse)
        let controller = JockRetargetTestController()
        controller.configureStoryBattleIdentity(
            id: UUID(),
            battleInstanceID: chapterRunID,
            enemyTypeID: "chapter02_spouse_window_presentation",
            archetype: .spouse,
            hitsToKill: 1,
            attributes: attributes
        )
        TuringMemoryBudgetProbe.log(label: "beforeChapter02SpouseSingleImport")
        try await controller.loadIfNeeded()
        TuringMemoryBudgetProbe.log(label: "afterChapter02SpouseSingleImport")
        controller.prepareFreshStoryBattleSpawn()
        try controller.requirePreparedAnimationIDs(presentationClipIDs)
        controller.setCombatEnabled(false)
        controller.setPlayerAttackEnabled(false)
        controller.setExternalMotionDriven(true)
        controller.setRootMotionEnabled(false)
        controller.useAuthoredCharacterHeadingCorrection()
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
        controller.rootEntity.isEnabled = false

        let lease = Chapter02WomanRuntimeLease(
            chapterRunID: chapterRunID,
            controller: controller,
            corpsePresenter: BattleCorpsePresentationController(
                storyRoot: sceneRoot
            ),
            heavyRuntimeRegistry: heavyRuntimeRegistry
        )
        await heavyRuntimeRegistry.register(.chapter02Woman(chapterRunID))
        print(
            "[Chapter02Woman] runtime prepared tier=windowPresentation " +
                "asset=spouse_biped.usdz importCountForRun=1 hidden=true"
        )
        return Chapter02WindowWomanRuntime(
            chapterRunID: chapterRunID,
            context: context,
            lease: lease
        )
    }

    static func installWorldPose(
        _ controller: JockRetargetTestController,
        floorPosition: SIMD3<Float>,
        orientation: simd_quatf
    ) {
        var position = floorPosition
        position.y = controller.rootYForFloorY(floorPosition.y)
        controller.rootEntity.setPosition(position, relativeTo: nil)
        controller.rootEntity.setOrientation(orientation, relativeTo: nil)
    }

    private static func stripInteraction(from entity: Entity) {
        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(CollisionComponent.self)
        for child in entity.children {
            stripInteraction(from: child)
        }
    }
}
