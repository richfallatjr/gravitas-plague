import Foundation
import RealityKit
import simd

@MainActor
final class Chapter01DadFinalBattleCoordinator {
    typealias EnemyRemovedHook = @MainActor (UUID) -> Void
    typealias PlayerTargetProvider = @MainActor () -> SIMD3<Float>?

    private let definitionStore = Chapter01DadFinalBattleDefinitionStore()
    private let prerecordingStore = TuringPrerecordingStore()
    private let enemyFactory: Chapter01DadBattleEnemyFactory
    private let door: any TuringStoryDoorBattleControlling
    private let arbiter: StoryInteractionArbiter
    private let clock: any BattleClock
    private let intro: ScriptedPortalEnemyIntroCoordinator
    private let music = Chapter01DadBattleMusicController()
    private let damageClock = Chapter01DadBattleDamageClock()
    private let richQueue: StoryBattleRichPrerecordingQueue
    private let enemyRegistry = BattleEnemyRuntimeRegistry()
    private let corpsePresenter: BattleCorpsePresentationController
    private let runtimeCleanup: BattleRuntimeCleanupCoordinator
    private let onEnemyRemoved: EnemyRemovedHook
    private let playerTargetProvider: PlayerTargetProvider
    private let onPlayerContactFeedback: @MainActor (Int) -> Void
    private let onPlayerDeath: @MainActor () -> Void
    private let onRuntimeReleased: @MainActor (Chapter01DadFinalBattleReleasedEvent) -> Void
    private weak var completionSink:
        (any Chapter01DadFinalBattleCompletionSink)?

    private(set) var state: Chapter01DadFinalBattleState = .unloaded
    private var chapterRunID: UUID?
    private var battleInstanceID: UUID?
    private var interactionLease: StoryInteractionLease?
    private var definition: Chapter01DadFinalBattleDefinition?
    private var prepared: ScriptedPortalPreparedEnemy?
    private var combat: Chapter01DadBattleCombatAdapter?
    private var musicEpoch: Chapter01DadBattleMusicEpoch?
    private var latestPlayerTarget: SIMD3<Float>?
    private var runTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var runtimeReleaseWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(
        sceneRoot: Entity,
        door: any TuringStoryDoorBattleControlling,
        clock: any BattleClock,
        richVocalChannel: any StoryRichVocalChannelControlling,
        arbiter: StoryInteractionArbiter = .shared,
        onEnemyPrepared: @escaping Chapter01DadBattleEnemyFactory.PreparedCallback,
        onEnemyRemoved: @escaping EnemyRemovedHook,
        playerTargetProvider: @escaping PlayerTargetProvider,
        onPlayerContactFeedback: @escaping @MainActor (Int) -> Void,
        onPlayerDeath: @escaping @MainActor () -> Void,
        onRuntimeReleased: @escaping @MainActor (
            Chapter01DadFinalBattleReleasedEvent
        ) -> Void = { _ in }
    ) {
        self.door = door
        self.arbiter = arbiter
        self.clock = clock
        self.richQueue = StoryBattleRichPrerecordingQueue(
            richVocalChannel: richVocalChannel
        )
        self.intro = ScriptedPortalEnemyIntroCoordinator(clock: clock)
        self.corpsePresenter = BattleCorpsePresentationController(
            storyRoot: sceneRoot
        )
        self.runtimeCleanup = BattleRuntimeCleanupCoordinator(
            registry: enemyRegistry,
            corpsePresenter: corpsePresenter
        )
        self.enemyFactory = Chapter01DadBattleEnemyFactory(
            sceneRoot: sceneRoot,
            onPrepared: onEnemyPrepared
        )
        self.onEnemyRemoved = onEnemyRemoved
        self.playerTargetProvider = playerTargetProvider
        self.onPlayerContactFeedback = onPlayerContactFeedback
        self.onPlayerDeath = onPlayerDeath
        self.onRuntimeReleased = onRuntimeReleased
    }

    var hasActiveRuntime: Bool {
        guard let battleInstanceID else {
            return door.battlePortalFullExteriorResident
        }
        return enemyRegistry.activeEnemyCount(
            battleInstanceID: battleInstanceID
        ) > 0 || door.battlePortalFullExteriorResident
    }

    func setCompletionSink(
        _ sink: (any Chapter01DadFinalBattleCompletionSink)?
    ) {
        completionSink = sink
    }

    func start(
        chapterRunID: UUID,
        battleInstanceID: UUID,
        interactionLease: StoryInteractionLease
    ) {
        guard state == .unloaded,
              self.battleInstanceID == nil,
              interactionLease.owner == .battle(
                battleInstanceID: battleInstanceID
              ) else {
            print(
                "[Chapter01DadBattle] rejected start state=\(state.rawValue) " +
                    "owner=\(interactionLease.owner.logValue)"
            )
            Task {
                await arbiter.release(
                    interactionLease,
                    reason: "chapter01DadBattle.invalidStart"
                )
            }
            return
        }

        self.chapterRunID = chapterRunID
        self.battleInstanceID = battleInstanceID
        self.interactionLease = interactionLease
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
        music.update()
        if state == .combatGracePeriod,
           combat?.damageIsEnabled == true {
            state = .combatLethal
            print(
                "[Chapter01DadBattle] lethal phase entered " +
                    "musicMediaTime=\(damageClock.currentMediaTime ?? 0)"
            )
        }
        prepared?.portalMirror.refreshPortalLightingIfNeeded()
        switch state {
        case .portalIdleFacingAway, .turnOne, .turnTwo, .approachingDoor,
             .waitingForDoor, .openingDoor, .portalCrossing:
            intro.update(deltaTime: deltaTime)
        case .combatGracePeriod, .combatLethal, .dadDeathAnimation:
            combat?.update(deltaTime: deltaTime)
        default:
            break
        }
    }

    func waitUntilRuntimeReleased() async {
        guard hasActiveRuntime else { return }
        let waiterID = UUID()
        await withCheckedContinuation { continuation in
            runtimeReleaseWaiters[waiterID] = continuation
        }
    }

    func cancel(reason: String) async {
        let instanceID = battleInstanceID
        state = .cancelled
        runTask?.cancel()
        cleanupTask?.cancel()
        runTask = nil
        cleanupTask = nil
        richQueue.cancel(battleInstanceID: instanceID, reason: reason)
        music.stop(epoch: musicEpoch, reason: reason)
        damageClock.reset()
        combat?.cancelAndRelease(reason: reason)
        combat = nil
        intro.cancelAndRelease(reason: reason)
        prepared = nil

        if let instanceID {
            await destructiveRelease(
                battleInstanceID: instanceID,
                reason: .battleCancelled,
                logReason: reason
            )
        } else {
            await releaseInteractionLease(reason: reason)
            resumeRuntimeReleaseWaiters()
        }
        resetTransientState(finalState: .unloaded)
    }

    private func run(
        chapterRunID: UUID,
        battleInstanceID: UUID
    ) async {
        do {
            let definition = try definitionStore.load()
            self.definition = definition
            let soundtrackURL = try definitionStore.soundtrackURL(
                for: definition
            )
            let timedCue = try makeCue(
                definition: definition,
                cue: definition.musicTimedRichCue,
                order: 0,
                battleInstanceID: battleInstanceID
            )
            let remainingCue = try makeCue(
                definition: definition,
                cue: definition.oneDamageRemainingRichCue,
                order: 1,
                battleInstanceID: battleInstanceID
            )
            richQueue.reserve(timedCue)
            try music.prepare(
                fileURL: soundtrackURL,
                gainDB: definition.music.gainDB
            )

            try await door.acquireBattlePortal(
                ownerID: battleInstanceID,
                reason: "chapter01DadBattle.prepare"
            )
            guard let interactionLease else { throw CancellationError() }
            try await arbiter.setBattleDoorPermission(
                .playerMayOpen,
                battleLease: interactionLease,
                reason: "chapter01DadBattle.portalApproach"
            )
            let doorContext = try door.battlePortalContext()
            let enemy = try await enemyFactory.prepare(
                definition: definition,
                doorContext: doorContext,
                battleInstanceID: battleInstanceID
            )
            try Task.checkCancellation()
            guard self.battleInstanceID == battleInstanceID else {
                throw CancellationError()
            }
            let enemyLease = BattleEnemyRuntimeLease(
                identity: enemy.sourceController.battleRuntimeIdentity,
                controller: enemy.sourceController,
                portalMirror: enemy.portalMirror
            )
            do {
                try enemyRegistry.register(enemyLease)
            } catch {
                _ = try? await enemyLease.release(
                    reason: .battleCancelled,
                    retentionPolicy: .remove,
                    corpsePresenter: corpsePresenter
                )
                throw error
            }
            prepared = enemy

            intro.install(
                prepared: enemy,
                doorContext: doorContext,
                configuration: ScriptedPortalEnemyIntroConfiguration(
                    idleDurationSeconds: definition.enemy.idleDurationSeconds,
                    turnCount: definition.enemy.turnCount,
                    turnDegreesPerCompletion:
                        definition.enemy.turnDegreesPerCompletion,
                    revealThresholdPortalLocalZMeters:
                        definition.portalHandoff
                            .revealThresholdPortalLocalZMeters,
                    exitThresholdPortalLocalZMeters:
                        definition.portalHandoff
                            .exitThresholdPortalLocalZMeters
                ),
                onInitialIdleStarted: { [weak self] in
                    guard let self,
                          self.battleInstanceID == battleInstanceID else {
                        throw CancellationError()
                    }
                    let epoch = try self.music.playOnce(
                        battleInstanceID: battleInstanceID
                    )
                    self.musicEpoch = epoch
                    self.damageClock.arm(music: self.music, epoch: epoch)
                    try self.music.installMediaTimeBoundary(
                        at: try definition.musicTimedRichCue
                            .triggerMediaTimeSeconds ?? 30,
                        epoch: epoch,
                        boundaryID: "dadBattleSongThirtySeconds"
                    ) { [weak self] returnedEpoch in
                        guard let self,
                              self.musicEpoch == returnedEpoch,
                              self.battleInstanceID == battleInstanceID else {
                            return
                        }
                        self.richQueue.releaseReservationAndEnqueue(
                            cueID: timedCue.cueID,
                            battleInstanceID: battleInstanceID
                        )
                    }
                },
                onStateChange: { [weak self] nextState in
                    guard self?.battleInstanceID == battleInstanceID else {
                        return
                    }
                    self?.applyIntroState(nextState)
                }
            )

            try await intro.performApproach()
            try Task.checkCancellation()
            guard self.battleInstanceID == battleInstanceID else { return }
            try await arbiter.setBattleDoorPermission(
                .hiddenAndLocked,
                battleLease: interactionLease,
                reason: "chapter01DadBattle.arrivedA3"
            )
            door.setBattleInteractionLocked(
                true,
                ownerID: battleInstanceID,
                reason: "chapter01DadBattle.arrivedA3"
            )
            if door.battleDoorState != .open {
                state = door.battleDoorState == .closed
                    ? .openingDoor
                    : .waitingForDoor
                try enemy.sourceController.playScriptedIdleLoop()
                try await door.openForBattle(
                    ownerID: battleInstanceID,
                    reason: "chapter01DadBattle.autoOpenAtA3"
                )
            }

            try await intro.performPortalCrossing()
            try Task.checkCancellation()
            guard self.battleInstanceID == battleInstanceID else { return }

            let combat = Chapter01DadBattleCombatAdapter(
                damageClock: damageClock,
                damageEnableMediaTime:
                    definition.music.damageEnableAtMediaTimeSeconds,
                confirmedHitsToKill:
                    definition.playerDamage.confirmedHitsToKillAfterEnable
            )
            self.combat = combat
            state = combat.damageIsEnabled
                ? .combatLethal
                : .combatGracePeriod
            try combat.activate(
                enemy: enemy.sourceController,
                context: Chapter01DadBattleCombatContext(
                    battleInstanceID: battleInstanceID,
                    playerTargetProvider: { [weak self] in
                        self?.latestPlayerTarget ?? self?.playerTargetProvider()
                    },
                    onPlayerContactFeedback: { [weak self] amount in
                        self?.onPlayerContactFeedback(amount)
                    },
                    onPlayerDeath: { [weak self] in
                        self?.handlePlayerDeath(
                            battleInstanceID: battleInstanceID
                        )
                    },
                    onOneAcceptedDamageRemaining: { [weak self] in
                        guard let self,
                              self.battleInstanceID == battleInstanceID else {
                            return
                        }
                        self.richQueue.enqueue(remainingCue)
                    },
                    onEnemyDeathStarted: { [weak self] in
                        guard self?.battleInstanceID == battleInstanceID else {
                            return
                        }
                        self?.state = .dadDeathAnimation
                    },
                    onEnemyDeathAnimationCompleted: { [weak self] in
                        self?.handleDadDeathAnimationCompleted(
                            battleInstanceID: battleInstanceID,
                            enemyID: enemy.enemyID
                        )
                    }
                )
            )
            runTask = nil
        } catch is CancellationError {
            return
        } catch {
            print(
                "[Chapter01DadBattle] ERROR run failed " +
                    "battleInstanceID=\(battleInstanceID.uuidString) " +
                    "error=\(error.localizedDescription)"
            )
            await cancel(reason: "runFailure.\(error.localizedDescription)")
        }
    }

    private func handleDadDeathAnimationCompleted(
        battleInstanceID: UUID,
        enemyID: UUID
    ) {
        guard self.battleInstanceID == battleInstanceID,
              cleanupTask == nil,
              let definition else { return }
        state = .dadDeathDialogueHold
        combat?.cancelAndRelease(reason: "Dad death animation completed")
        combat = nil
        intro.cancelAndRelease(reason: "Dad death animation completed")
        print(
            "[Chapter01DadBattle] completed death pose retained " +
                "battleInstanceID=\(battleInstanceID.uuidString) " +
                "untilRichQueueDrained=true"
        )

        cleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let doorCloseTask = Task { @MainActor [door = self.door] in
                try await door.closeForBattleAndUnloadPortal(
                    ownerID: battleInstanceID,
                    reason: "chapter01DadBattle.deathDialogueHold"
                )
            }
            await self.richQueue.waitUntilDrained(
                battleInstanceID: battleInstanceID
            )
            guard self.battleInstanceID == battleInstanceID else { return }
            self.state = .releasingRuntime
            do {
                if let musicEpoch = self.musicEpoch {
                    try await self.music.fadeOutAndStop(
                        epoch: musicEpoch,
                        durationSeconds:
                            definition.music.fadeOutDurationSeconds,
                        reason: "Dad Rich battle dialogue completed"
                    )
                } else {
                    self.music.stop(
                        epoch: nil,
                        reason: "Dad battle cleanup without active epoch"
                    )
                }
                self.damageClock.reset()
                let bodyHoldSeconds =
                    definition.enemy.removalDelayAfterMusicEndSeconds
                if bodyHoldSeconds > 0 {
                    print(
                        "[Chapter01DadBattle] post-music body hold started " +
                            "durationSeconds=\(bodyHoldSeconds)"
                    )
                    try await self.clock.sleep(
                        for: .seconds(bodyHoldSeconds)
                    )
                    try Task.checkCancellation()
                    guard self.battleInstanceID == battleInstanceID else {
                        throw CancellationError()
                    }
                    print("[Chapter01DadBattle] post-music body hold completed")
                }
                try await doorCloseTask.value
                self.onEnemyRemoved(enemyID)
                // The registry's release proof is based on the controller's weak
                // lifetime. Drop the coordinator-owned prepared graph before the
                // lease clears and verifies the controller.
                self.prepared = nil
                print(
                    "[Chapter01DadBattle] coordinator prepared enemy released " +
                        "enemyID=\(enemyID.uuidString) beforeRegistryProof=true"
                )
                _ = try await self.runtimeCleanup.releaseEnemy(
                    battleInstanceID: battleInstanceID,
                    enemyID: enemyID,
                    reason: .neutralized,
                    retentionPolicy: .remove
                )
                let report = try await self.runtimeCleanup.releaseBattle(
                    battleInstanceID: battleInstanceID,
                    reason: .battleCompleted,
                    retentionPolicy: .remove,
                    fullPortalReleased:
                        !self.door.battlePortalFullExteriorResident,
                    musicStillPlaying: false
                )
                try await self.finishRuntimeRelease(
                    chapterRunID: self.chapterRunID,
                    battleInstanceID: battleInstanceID,
                    report: report,
                    finalState: .completed
                )
            } catch {
                print(
                    "[Chapter01DadBattle] ERROR authored death cleanup failed " +
                        "error=\(error.localizedDescription)"
                )
                await self.cancel(
                    reason: "deathCleanupFailure.\(error.localizedDescription)"
                )
            }
        }
    }

    private func handlePlayerDeath(battleInstanceID: UUID) {
        guard self.battleInstanceID == battleInstanceID,
              state != .playerDead else { return }
        state = .playerDead
        combat?.cancelAndRelease(reason: "playerDeath")
        combat = nil
        richQueue.cancel(
            battleInstanceID: battleInstanceID,
            reason: "playerDeath"
        )
        music.stop(epoch: musicEpoch, reason: "playerDeath")
        damageClock.reset()
        intro.cancelAndRelease(reason: "playerDeath")
        cleanupTask?.cancel()
        cleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.destructiveRelease(
                battleInstanceID: battleInstanceID,
                reason: .battleCancelled,
                logReason: "playerDeath"
            )
        }
        onPlayerDeath()
    }

    private func destructiveRelease(
        battleInstanceID: UUID,
        reason: BattleEnemyReleaseReason,
        logReason: String
    ) async {
        let enemyID = prepared?.enemyID
        prepared = nil
        if let enemyID { onEnemyRemoved(enemyID) }
        do {
            try await door.closeForBattleAndUnloadPortal(
                ownerID: battleInstanceID,
                reason: logReason
            )
        } catch {
            door.releaseBattlePortal(
                ownerID: battleInstanceID,
                reason: "\(logReason).closeFailure"
            )
            print(
                "[Chapter01DadBattle] door cleanup failed " +
                    "error=\(error.localizedDescription)"
            )
        }
        do {
            _ = try await runtimeCleanup.releaseBattle(
                battleInstanceID: battleInstanceID,
                reason: reason,
                retentionPolicy: .remove,
                fullPortalReleased: !door.battlePortalFullExteriorResident,
                musicStillPlaying: false
            )
        } catch {
            print(
                "[Chapter01DadBattle] runtime cleanup failed " +
                    "error=\(error.localizedDescription)"
            )
        }
        await releaseInteractionLease(reason: logReason)
        if self.battleInstanceID == battleInstanceID {
            self.battleInstanceID = nil
            chapterRunID = nil
            musicEpoch = nil
        }
        resumeRuntimeReleaseWaiters()
    }

    private func finishRuntimeRelease(
        chapterRunID: UUID?,
        battleInstanceID: UUID,
        report: BattleRuntimeReleaseReport,
        finalState: Chapter01DadFinalBattleState
    ) async throws {
        guard let chapterRunID,
              let interactionLease,
              let completionSink else {
            throw Chapter01Error.missingDadFinalBattleCompletionSink
        }
        let event = Chapter01DadFinalBattleReleasedEvent(
            eventID: UUID(),
            chapterRunID: chapterRunID,
            battleInstanceID: battleInstanceID,
            battleLease: interactionLease,
            releaseReport: report,
            doorState: door.battleDoorState,
            richBattleQueueDrained: richQueue.isDrained(
                battleInstanceID: battleInstanceID
            )
        )
        guard event.isSafeForFinalDadFrame else {
            throw Chapter01Error.dadFinalBattleReleaseBoundaryFailed
        }

        state = .awaitingFinalDadFrameHandoff
        print(
            "[Chapter01DadBattle] successful release boundary " +
                "chapterRunID=\(chapterRunID.uuidString) " +
                "battleInstanceID=\(battleInstanceID.uuidString) " +
                "completionEventID=\(event.eventID.uuidString) " +
                "doorState=\(event.doorState.rawValue) " +
                "fullExteriorResident=\(!report.fullPortalReleased) " +
                "musicActive=\(report.musicStillPlaying) " +
                "richQueueDrained=\(event.richBattleQueueDrained) " +
                "safeForFinalDadFrame=\(event.isSafeForFinalDadFrame)"
        )
        try await completionSink.dadFinalBattleCompleted(event)

        // The sink atomically transfers this lease to storyTransition.
        // Clearing the stale local reference prevents a second release.
        self.interactionLease = nil
        onRuntimeReleased(event)
        prepared = nil
        definition = nil
        self.chapterRunID = nil
        self.battleInstanceID = nil
        musicEpoch = nil
        cleanupTask = nil
        state = finalState
        resumeRuntimeReleaseWaiters()
    }

    private func makeCue(
        definition: Chapter01DadFinalBattleDefinition,
        cue: Chapter01DadFinalBattleDefinition.RichPrerecordedCue,
        order: Int,
        battleInstanceID: UUID
    ) throws -> StoryBattleRichPrerecordingQueue.Cue {
        let descriptor = try prerecordingStore.descriptor(
            id: cue.prerecordingID
        )
        let fileURL = try prerecordingStore.audioURL(for: descriptor)
        return StoryBattleRichPrerecordingQueue.Cue(
            cueID: cue.cueID,
            order: order,
            descriptor: descriptor,
            fileURL: fileURL,
            battleInstanceID: battleInstanceID,
            gainDB: cue.gainDB
        )
    }

    private func applyIntroState(
        _ nextState: ScriptedPortalEnemyIntroState
    ) {
        switch nextState {
        case .portalIdleFacingAway:
            state = .portalIdleFacingAway
        case .turnOne:
            state = .turnOne
        case .turnTwo:
            state = .turnTwo
        case .approachingDoor:
            state = .approachingDoor
        case .portalCrossing:
            state = .portalCrossing
        }
    }

    private func releaseInteractionLease(reason: String) async {
        guard let interactionLease else { return }
        self.interactionLease = nil
        await arbiter.release(interactionLease, reason: reason)
    }

    private func resumeRuntimeReleaseWaiters() {
        let waiters = Array(runtimeReleaseWaiters.values)
        runtimeReleaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private func resetTransientState(
        finalState: Chapter01DadFinalBattleState
    ) {
        chapterRunID = nil
        battleInstanceID = nil
        interactionLease = nil
        definition = nil
        prepared = nil
        combat = nil
        musicEpoch = nil
        latestPlayerTarget = nil
        state = finalState
    }
}
