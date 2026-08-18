import Foundation
import RealityKit
import simd

@MainActor
protocol Chapter02WomanBattleCompletionSink: AnyObject {
    func womanBattleReleased(
        _ event: Chapter02WomanBattleReleasedEvent
    ) async throws
    func womanBattleFailed(chapterRunID: UUID, message: String) async
}

@MainActor
final class Chapter02WomanBattleCoordinator {
    enum State: String, Sendable {
        case unloaded
        case preparing
        case portalIntro
        case openingDoor
        case portalCrossing
        case combat
        case releasing
        case released
        case failed
        case cancelled
    }

    private let sceneRoot: Entity
    private let door: any TuringStoryDoorBattleControlling
    private let intro = ScriptedPortalEnemyIntroCoordinator(
        clock: ProductionBattleClock()
    )
    private let combat: any Battle01StoryCombatControlling =
        Battle01StoryCombatAdapter()
    private let registry = BattleEnemyRuntimeRegistry()
    private let corpsePresenter: BattleCorpsePresentationController
    private let cleanup: BattleRuntimeCleanupCoordinator
    private let richPR: Chapter02PrerecordingPlayer
    private let onEnemyPrepared:
        @MainActor (UUID, JockRetargetTestController) -> Void
    private let onEnemyRemoved: @MainActor (UUID) -> Void
    private let playerTargetProvider: @MainActor () -> SIMD3<Float>?
    private let onPlayerDamage: @MainActor (Float) -> Void

    private(set) var state: State = .unloaded
    private var chapterRunID: UUID?
    private var battleInstanceID: UUID?
    private var battleLease: StoryInteractionLease?
    private var womanLease: Chapter02WomanRuntimeLease?
    private var prepared: ScriptedPortalPreparedEnemy?
    private weak var completionSink:
        (any Chapter02WomanBattleCompletionSink)?
    private var runTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var richPRTask: Task<Void, Error>?
    private var latestPlayerTarget: SIMD3<Float>?

    init(
        sceneRoot: Entity,
        door: any TuringStoryDoorBattleControlling,
        richVocalChannel: any StoryRichVocalChannelControlling,
        onEnemyPrepared: @escaping @MainActor (
            UUID,
            JockRetargetTestController
        ) -> Void,
        onEnemyRemoved: @escaping @MainActor (UUID) -> Void,
        playerTargetProvider: @escaping @MainActor () -> SIMD3<Float>?,
        onPlayerDamage: @escaping @MainActor (Float) -> Void
    ) {
        self.sceneRoot = sceneRoot
        self.door = door
        self.richPR = Chapter02PrerecordingPlayer(
            richVocalChannel: richVocalChannel
        )
        self.onEnemyPrepared = onEnemyPrepared
        self.onEnemyRemoved = onEnemyRemoved
        self.playerTargetProvider = playerTargetProvider
        self.onPlayerDamage = onPlayerDamage
        let corpsePresenter = BattleCorpsePresentationController(
            storyRoot: sceneRoot
        )
        self.corpsePresenter = corpsePresenter
        self.cleanup = BattleRuntimeCleanupCoordinator(
            registry: registry,
            corpsePresenter: corpsePresenter
        )
    }

    func start(
        chapterRunID: UUID,
        runtime: Chapter02WindowWomanRuntime,
        battleInstanceID: UUID,
        battleLease: StoryInteractionLease,
        completionSink: any Chapter02WomanBattleCompletionSink
    ) {
        guard state == .unloaded,
              battleLease.owner == .battle(
                battleInstanceID: battleInstanceID
              ) else {
            Task {
                await StoryInteractionArbiter.shared.release(
                    battleLease,
                    reason: "chapter02WomanBattle.invalidStart"
                )
            }
            return
        }
        self.chapterRunID = chapterRunID
        self.battleInstanceID = battleInstanceID
        self.battleLease = battleLease
        womanLease = runtime.lease
        self.completionSink = completionSink
        state = .preparing
        runTask = Task { @MainActor [weak self] in
            await self?.run(
                chapterRunID: chapterRunID,
                battleInstanceID: battleInstanceID
            )
        }
    }

    func update(
        deltaTime: TimeInterval,
        playerTargetWorldPosition: SIMD3<Float>?
    ) {
        latestPlayerTarget = playerTargetWorldPosition
        prepared?.portalMirror.refreshPortalLightingIfNeeded()
        switch state {
        case .portalIntro, .openingDoor, .portalCrossing:
            intro.update(deltaTime: deltaTime)
        case .combat:
            combat.update(deltaTime: deltaTime)
        default:
            break
        }
    }

    func cancel(reason: String) async {
        let instanceID = battleInstanceID
        state = .cancelled
        runTask?.cancel()
        cleanupTask?.cancel()
        richPRTask?.cancel()
        runTask = nil
        cleanupTask = nil
        richPRTask = nil
        await richPR.cancel(reason: reason)
        await Chapter02BattleMusicActor.shared.stop(
            reason: "chapter02WomanBattle.cancel.\(reason)"
        )
        combat.cancelAndRelease(reason: reason)
        intro.cancelAndRelease(reason: reason)
        let enemyID = prepared?.enemyID
        prepared = nil
        if let enemyID {
            onEnemyRemoved(enemyID)
        }
        if let instanceID {
            do {
                try await door.closeForBattleAndUnloadPortal(
                    ownerID: instanceID,
                    reason: reason
                )
            } catch {
                door.releaseBattlePortal(
                    ownerID: instanceID,
                    reason: "chapter02CancelCloseFailed.\(reason)"
                )
            }
            if cleanup.hasActiveEnemyRuntime {
                _ = try? await cleanup.releaseBattle(
                    battleInstanceID: instanceID,
                    reason: .battleCancelled,
                    retentionPolicy: .remove,
                    fullPortalReleased:
                        !door.battlePortalFullExteriorResident,
                    musicStillPlaying: false
                )
            } else {
                _ = try? await womanLease?.release(
                    reason: .battleCancelled
                )
            }
        } else {
            _ = try? await womanLease?.release(reason: .battleCancelled)
        }
        await womanLease?.markReleased()
        if let battleLease {
            await StoryInteractionArbiter.shared.release(
                battleLease,
                reason: reason
            )
        }
        resetTransient(finalState: .unloaded)
    }

    private func run(
        chapterRunID: UUID,
        battleInstanceID: UUID
    ) async {
        do {
            try await door.acquireBattlePortal(
                ownerID: battleInstanceID,
                reason: "chapter02WomanAnimationPresent"
            )
            guard let battleLease, let womanLease else {
                throw Chapter02Error.invalidRuntimeTransfer(
                    "battle ownership disappeared"
                )
            }
            let doorContext = try door.battlePortalContext()
            let battle01Definition = try Battle01DefinitionStore().load()
            let source = try womanLease.prepareCombatIdentity(
                battleInstanceID: battleInstanceID
            )
            try source.requirePreparedAnimationIDs([
                "idle_01",
                "turn_right_90",
                "unstable_walk_01",
                "dead_fall_forward_01",
                "dead_fall_backward_01"
            ])
            source.rootEntity.removeFromParent()
            sceneRoot.addChild(source.rootEntity)

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
                simd_quatf(
                    angle: initialYaw,
                    axis: SIMD3<Float>(0, 1, 0)
                ),
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
                enemyID: source.hordeBenchmarkID,
                characterID: "spouse",
                reason: "Chapter02WomanBattle.authoritativeSource"
            )
            onEnemyPrepared(source.hordeBenchmarkID, source)
            let mirror = try StoryPortalEnemyRenderMirrorAdapter(
                source: source,
                portalWorldRoot: doorContext.portalWorldRoot,
                portalPlaneEntity: doorContext.portalPlane
            )
            source.rootEntity.isEnabled = false
            let prepared = ScriptedPortalPreparedEnemy(
                enemyID: source.hordeBenchmarkID,
                sourceController: source,
                sourceRoot: source.rootEntity,
                portalMirror: mirror
            )
            self.prepared = prepared
            try await Chapter02BattleMusicActor.shared.startIfNeeded(
                reason: "chapter02WomanBattle.portalLoaded.ensureActive"
            )

            let registryController = try womanLease
                .relinquishControllerToBattleRegistry()
            try registry.register(
                BattleEnemyRuntimeLease(
                    identity: registryController.battleRuntimeIdentity,
                    controller: registryController,
                    portalMirror: mirror
                )
            )

            try await StoryInteractionArbiter.shared.setBattleDoorPermission(
                .playerMayOpen,
                battleLease: battleLease,
                reason: "chapter02Woman.loaded"
            )
            state = .portalIntro
            intro.install(
                prepared: prepared,
                doorContext: doorContext,
                configuration: ScriptedPortalEnemyIntroConfiguration(
                    idleDurationSeconds:
                        battle01Definition.enemy.idleDurationSeconds,
                    turnCount: battle01Definition.enemy.turnCount,
                    turnDegreesPerCompletion:
                        battle01Definition.enemy.turnDegreesPerCompletion,
                    revealThresholdPortalLocalZMeters:
                        battle01Definition.portalHandoff
                            .revealThresholdPortalLocalZMeters,
                    exitThresholdPortalLocalZMeters:
                        battle01Definition.portalHandoff
                            .exitThresholdPortalLocalZMeters
                ),
                onInitialIdleStarted: {},
                onStateChange: { [weak self] _ in
                    guard self?.battleInstanceID == battleInstanceID else {
                        return
                    }
                }
            )
            try await intro.performApproach()
            try Task.checkCancellation()

            try await StoryInteractionArbiter.shared.setBattleDoorPermission(
                .hiddenAndLocked,
                battleLease: battleLease,
                reason: "chapter02Woman.atA3"
            )
            door.setBattleInteractionLocked(
                true,
                ownerID: battleInstanceID,
                reason: "chapter02Woman.atA3"
            )
            if door.battleDoorState != .open {
                state = .openingDoor
                try source.playScriptedIdleLoop()
                try await door.openForBattle(
                    ownerID: battleInstanceID,
                    reason: "chapter02Woman.pushDoor"
                )
            }
            guard door.battleDoorState == .open else {
                throw Chapter02Error.invalidRuntimeTransfer(
                    "Rich battle PR requires the door to be fully open"
                )
            }
            startRichBattlePR(battleInstanceID: battleInstanceID)
            state = .portalCrossing
            try await intro.performPortalCrossing()
            try Task.checkCancellation()

            state = .combat
            try combat.activate(
                enemy: source,
                context: StoryEnemyCombatContext(
                    battleInstanceID: battleInstanceID,
                    playerTargetProvider: { [weak self] in
                        self?.latestPlayerTarget ?? self?.playerTargetProvider()
                    },
                    onPlayerDamage: { [weak self] amount in
                        self?.onPlayerDamage(amount)
                    },
                    onEnemyDeathStarted: {},
                    onEnemyDeathAnimationCompleted: { [weak self] in
                        guard self?.battleInstanceID == battleInstanceID else {
                            return
                        }
                        self?.scheduleCleanup(
                            chapterRunID: chapterRunID,
                            battleInstanceID: battleInstanceID,
                            enemyID: prepared.enemyID
                        )
                    }
                )
            )
            runTask = nil
        } catch is CancellationError {
            await cancel(reason: "chapter02WomanBattle.cancelled")
        } catch {
            state = .failed
            await completionSink?.womanBattleFailed(
                chapterRunID: chapterRunID,
                message: error.localizedDescription
            )
            await cancel(reason: "chapter02WomanBattle.failed")
        }
    }

    private func scheduleCleanup(
        chapterRunID: UUID,
        battleInstanceID: UUID,
        enemyID: UUID
    ) {
        guard cleanupTask == nil else { return }
        state = .releasing
        cleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let richPRTask = self.richPRTask {
                    _ = try await richPRTask.value
                }
                self.richPRTask = nil
                self.combat.cancelAndRelease(
                    reason: "chapter02WomanBattle.deathComplete"
                )
                self.intro.cancelAndRelease(
                    reason: "chapter02WomanBattle.deathComplete"
                )
                self.prepared = nil
                self.onEnemyRemoved(enemyID)

                _ = try await self.cleanup.releaseEnemy(
                    battleInstanceID: battleInstanceID,
                    enemyID: enemyID,
                    reason: .neutralized,
                    retentionPolicy: .remove
                )
                await self.womanLease?.markReleased()
                await Chapter02BattleMusicActor.shared
                    .fadeToPostBattleLevel(
                        reason: "chapter02WomanBattle.geometryReleased"
                    )
                try await self.door.closeForBattleAndUnloadPortal(
                    ownerID: battleInstanceID,
                    reason: "chapter02WomanBattle.enemyReleased"
                )
                let report = try await self.cleanup.releaseBattle(
                    battleInstanceID: battleInstanceID,
                    reason: .battleCompleted,
                    retentionPolicy: .remove,
                    fullPortalReleased:
                        !self.door.battlePortalFullExteriorResident,
                    musicStillPlaying:
                        await Chapter02BattleMusicActor.shared
                            .hasActiveSession()
                )
                self.door.setBattleInteractionLocked(
                    false,
                    ownerID: battleInstanceID,
                    reason: "chapter02WomanBattle.released"
                )
                if let battleLease = self.battleLease {
                    await StoryInteractionArbiter.shared.release(
                        battleLease,
                        reason: "chapter02WomanBattle.released"
                    )
                }
                self.battleLease = nil
                self.state = .released
                try await self.completionSink?.womanBattleReleased(
                    Chapter02WomanBattleReleasedEvent(
                        chapterRunID: chapterRunID,
                        battleInstanceID: battleInstanceID,
                        heavyRuntimeReleased:
                            report.allHeavyEnemyRuntimesReleased,
                        fullPortalReleased: report.fullPortalReleased
                    )
                )
                self.resetTransient(finalState: .unloaded)
            } catch {
                self.state = .failed
                await self.completionSink?.womanBattleFailed(
                    chapterRunID: chapterRunID,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func startRichBattlePR(battleInstanceID: UUID) {
        guard richPRTask == nil else { return }
        richPRTask = Task {
            try await richPR.play(
                resourcePath:
                    "Turing/Audio/prerecordings/pr-rich-women-battle.mp3",
                runID:
                    "chapter02.womanBattle.\(battleInstanceID.uuidString)",
                label: "chapter02.womanBattle.richPR",
                battleInstanceID: battleInstanceID
            )
        }
        print(
            "[Chapter02WomanBattle] Rich PR started after door fully opened " +
                "battleInstanceID=\(battleInstanceID.uuidString)"
        )
    }

    private func resetTransient(finalState: State) {
        chapterRunID = nil
        battleInstanceID = nil
        battleLease = nil
        womanLease = nil
        prepared = nil
        completionSink = nil
        runTask = nil
        cleanupTask = nil
        richPRTask = nil
        latestPlayerTarget = nil
        state = finalState
    }
}
