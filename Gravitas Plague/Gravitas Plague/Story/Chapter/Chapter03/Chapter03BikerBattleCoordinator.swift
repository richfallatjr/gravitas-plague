import Foundation
import RealityKit
import simd

struct Chapter03BikerBattleReleasedEvent: Sendable {
    let eventID: UUID
    let chapterRunID: UUID
    let battleInstanceID: UUID
    let battleLease: StoryInteractionLease
    let releaseReport: BattleRuntimeReleaseReport
}

@MainActor
protocol Chapter03BikerBattleCompletionSink: AnyObject {
    func chapter03BikerBattleReleased(
        _ event: Chapter03BikerBattleReleasedEvent
    ) async throws
    func chapter03BikerBattleFailed(chapterRunID: UUID, error: Error) async
}

@MainActor
final class Chapter03BikerBattleCoordinator {
    private let definitionStore = Chapter03BattleDefinitionStore()
    private let prerecordingStore = TuringPrerecordingStore()
    private let enemyFactory: Chapter03BattleEnemyFactory
    private let door: any TuringStoryDoorBattleControlling
    private let arbiter: StoryInteractionArbiter
    private let intro: ScriptedPortalEnemyIntroCoordinator
    private let music: Chapter03BattleMusicController
    private let richQueue: StoryBattleRichPrerecordingQueue
    private let registry = BattleEnemyRuntimeRegistry()
    private let cleanup: BattleRuntimeCleanupCoordinator
    private let onEnemyRemoved: @MainActor (UUID) -> Void
    private let playerTargetProvider: @MainActor () -> SIMD3<Float>?
    private let onPlayerContactFeedback: @MainActor (Int) -> Void
    private let onPlayerDeath: @MainActor () -> Void

    private weak var completionSink: (any Chapter03BikerBattleCompletionSink)?
    private var chapterRunID: UUID?
    private var battleInstanceID: UUID?
    private var battleLease: StoryInteractionLease?
    private var definition: Chapter03BattleDefinition?
    private var prepared: ScriptedPortalPreparedEnemy?
    private var combat: Chapter03BikerBattleCombatAdapter?
    private var doorObservation: TuringStoryDoorBattleOpeningObservation?
    private var musicEpoch: Chapter03BattleMusicEpoch?
    private var recognitionCue: StoryBattleRichPrerecordingQueue.Cue?
    private var handledDoorEvents = Set<UUID>()
    private var latestPlayerTarget: SIMD3<Float>?
    private var runTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?

    init(
        sceneRoot: Entity,
        door: any TuringStoryDoorBattleControlling,
        music: Chapter03BattleMusicController,
        richVocalChannel: any StoryRichVocalChannelControlling,
        clock: any BattleClock = ProductionBattleClock(),
        arbiter: StoryInteractionArbiter = .shared,
        onEnemyPrepared: @escaping Chapter03BattleEnemyFactory.PreparedCallback,
        onEnemyRemoved: @escaping @MainActor (UUID) -> Void,
        playerTargetProvider: @escaping @MainActor () -> SIMD3<Float>?,
        onPlayerContactFeedback: @escaping @MainActor (Int) -> Void,
        onPlayerDeath: @escaping @MainActor () -> Void
    ) {
        self.door = door
        self.music = music
        self.richQueue = StoryBattleRichPrerecordingQueue(
            richVocalChannel: richVocalChannel
        )
        self.arbiter = arbiter
        self.intro = ScriptedPortalEnemyIntroCoordinator(clock: clock)
        self.enemyFactory = Chapter03BattleEnemyFactory(
            sceneRoot: sceneRoot,
            onPrepared: onEnemyPrepared
        )
        self.onEnemyRemoved = onEnemyRemoved
        self.playerTargetProvider = playerTargetProvider
        self.onPlayerContactFeedback = onPlayerContactFeedback
        self.onPlayerDeath = onPlayerDeath
        self.cleanup = BattleRuntimeCleanupCoordinator(
            registry: registry,
            corpsePresenter: BattleCorpsePresentationController(storyRoot: sceneRoot)
        )
    }

    func prepare(
        chapterRunID: UUID,
        battleInstanceID: UUID,
        battleLease: StoryInteractionLease,
        completionSink: any Chapter03BikerBattleCompletionSink
    ) async throws {
        try await arbiter.requireCurrent(battleLease)
        let definition = try definitionStore.load(.biker)
        try music.prepare(definition: definition)
        let cue = try makeCue(
            definition.richCues[0],
            order: 0,
            battleInstanceID: battleInstanceID
        )
        richQueue.reserve(cue)

        self.chapterRunID = chapterRunID
        self.battleInstanceID = battleInstanceID
        self.battleLease = battleLease
        self.completionSink = completionSink
        self.definition = definition
        recognitionCue = cue
        handledDoorEvents.removeAll(keepingCapacity: false)

        try await door.acquireBattlePortal(
            ownerID: battleInstanceID,
            reason: "chapter03.biker.prepare"
        )
        try await arbiter.setBattleDoorPermission(
            .playerMayOpen,
            battleLease: battleLease,
            reason: "chapter03.biker.portalApproach"
        )
        doorObservation = door.observeBattleDoorOpening(
            ownerID: battleInstanceID
        ) { [weak self] event in
            self?.handleDoorOpening(event)
        }
        let doorContext = try door.battlePortalContext()
        let enemy = try await enemyFactory.prepareBiker(
            definition: definition,
            doorContext: doorContext,
            battleInstanceID: battleInstanceID
        )
        let lease = BattleEnemyRuntimeLease(
            identity: enemy.sourceController.battleRuntimeIdentity,
            controller: enemy.sourceController,
            portalMirror: enemy.portalMirror
        )
        try registry.register(lease)
        prepared = enemy
        intro.install(
            prepared: enemy,
            doorContext: doorContext,
            configuration: ScriptedPortalEnemyIntroConfiguration(
                idleDurationSeconds: definition.enemy.idleDurationSeconds,
                turnCount: definition.enemy.turnCount,
                turnDegreesPerCompletion: definition.enemy.turnDegreesPerCompletion,
                revealThresholdPortalLocalZMeters: 0.02,
                exitThresholdPortalLocalZMeters: 0.08
            ),
            onStateChange: { _ in }
        )
        print(
            "[Chapter03BikerBattle] prepared under black chapterRunID=\(chapterRunID.uuidString) battleInstanceID=\(battleInstanceID.uuidString)"
        )
    }

    func beginPreparedOpening() throws {
        guard let chapterRunID, let battleInstanceID, runTask == nil else {
            throw Chapter03Error.staleRun
        }
        runTask = Task { @MainActor [weak self] in
            await self?.runOpening(
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
        if combat != nil {
            combat?.update(deltaTime: deltaTime)
        } else {
            intro.update(deltaTime: deltaTime)
        }
    }

    func cancel(reason: String) async {
        let instanceID = battleInstanceID
        runTask?.cancel()
        cleanupTask?.cancel()
        runTask = nil
        cleanupTask = nil
        doorObservation?.cancel()
        doorObservation = nil
        richQueue.cancel(battleInstanceID: instanceID, reason: reason)
        combat?.cancelAndRelease(reason: reason)
        combat = nil
        intro.cancelAndRelease(reason: reason)
        music.stopAll(reason: reason)
        if let instanceID {
            await destructiveRelease(instanceID: instanceID, reason: reason)
        }
        clear()
    }

    private func runOpening(chapterRunID: UUID, battleInstanceID: UUID) async {
        do {
            try await intro.performApproach()
            try Task.checkCancellation()
            guard self.chapterRunID == chapterRunID,
                  self.battleInstanceID == battleInstanceID,
                  let battleLease,
                  let prepared,
                  let definition else { throw Chapter03Error.staleRun }
            try await arbiter.setBattleDoorPermission(
                .hiddenAndLocked,
                battleLease: battleLease,
                reason: "chapter03.biker.arrivedA3"
            )
            door.setBattleInteractionLocked(
                true,
                ownerID: battleInstanceID,
                reason: "chapter03.biker.arrivedA3"
            )
            if door.battleDoorState != .open {
                try prepared.sourceController.playScriptedIdleLoop()
                try await door.openForBattle(
                    ownerID: battleInstanceID,
                    reason: "chapter03.biker.autoOpenAtA3"
                )
            }
            try await intro.performPortalCrossing()
            let combat = Chapter03BikerBattleCombatAdapter(
                confirmedHitsToKill: definition.playerConfirmedHitsToKill
            )
            self.combat = combat
            try combat.activate(
                enemy: prepared.sourceController,
                context: Chapter03BikerCombatContext(
                    battleInstanceID: battleInstanceID,
                    playerTargetProvider: { [weak self] in
                        self?.latestPlayerTarget ?? self?.playerTargetProvider()
                    },
                    onPlayerContactFeedback: { [weak self] amount in
                        self?.onPlayerContactFeedback(amount)
                    },
                    onPlayerDeath: { [weak self] in
                        self?.handlePlayerDeath(battleInstanceID: battleInstanceID)
                    },
                    onEnemyDeathStarted: {},
                    onEnemyDeathAnimationCompleted: { [weak self] in
                        self?.handleDeathCompleted(
                            chapterRunID: chapterRunID,
                            battleInstanceID: battleInstanceID
                        )
                    }
                )
            )
        } catch is CancellationError {
        } catch {
            await fail(chapterRunID: chapterRunID, error: error)
        }
    }

    private func handleDoorOpening(_ event: TuringStoryDoorBattleOpeningBeganEvent) {
        guard event.battleInstanceID == battleInstanceID,
              handledDoorEvents.insert(event.eventID).inserted,
              let battleInstanceID,
              let recognitionCue else { return }
        do {
            musicEpoch = try music.start(
                lane: .biker,
                battleInstanceID: battleInstanceID,
                triggerEventID: event.eventID
            )
            richQueue.releaseReservationAndEnqueue(
                cueID: recognitionCue.cueID,
                battleInstanceID: battleInstanceID
            )
        } catch {
            Task { @MainActor [weak self] in
                guard let self, let chapterRunID = self.chapterRunID else { return }
                await self.fail(chapterRunID: chapterRunID, error: error)
            }
        }
    }

    private func handleDeathCompleted(
        chapterRunID: UUID,
        battleInstanceID: UUID
    ) {
        guard cleanupTask == nil else { return }
        cleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.combat?.cancelAndRelease(reason: "authoredDeathCompleted")
                self.combat = nil
                self.intro.cancelAndRelease(reason: "authoredDeathCompleted")
                async let scoreFade: Void = self.music.fadeOutAndStopAll(
                    battleInstanceID: battleInstanceID,
                    durationSeconds: 2,
                    reason: "bikerDeath"
                )
                await self.richQueue.waitUntilDrained(battleInstanceID: battleInstanceID)
                try await scoreFade
                self.doorObservation?.cancel()
                self.doorObservation = nil
                if let enemyID = self.prepared?.enemyID {
                    self.onEnemyRemoved(enemyID)
                }
                self.prepared = nil
                try await self.door.closeForBattleAndUnloadPortal(
                    ownerID: battleInstanceID,
                    reason: "chapter03.biker.deathCleanup"
                )
                let report = try await self.cleanup.releaseBattle(
                    battleInstanceID: battleInstanceID,
                    reason: .battleCompleted,
                    retentionPolicy: .remove,
                    fullPortalReleased: !self.door.battlePortalFullExteriorResident,
                    musicStillPlaying: self.music.activeHandleCount > 0
                )
                guard let battleLease = self.battleLease,
                      let completionSink = self.completionSink else {
                    throw Chapter03Error.staleRun
                }
                try await completionSink.chapter03BikerBattleReleased(
                    Chapter03BikerBattleReleasedEvent(
                        eventID: UUID(),
                        chapterRunID: chapterRunID,
                        battleInstanceID: battleInstanceID,
                        battleLease: battleLease,
                        releaseReport: report
                    )
                )
                self.battleLease = nil
                self.clear()
            } catch {
                await self.fail(chapterRunID: chapterRunID, error: error)
            }
        }
    }

    private func handlePlayerDeath(battleInstanceID: UUID) {
        guard self.battleInstanceID == battleInstanceID else { return }
        richQueue.cancel(battleInstanceID: battleInstanceID, reason: "playerDeath")
        combat?.cancelAndRelease(reason: "playerDeath")
        combat = nil
        intro.cancelAndRelease(reason: "playerDeath")
        music.stopAll(reason: "playerDeath")
        cleanupTask = Task { @MainActor [weak self] in
            await self?.destructiveRelease(instanceID: battleInstanceID, reason: "playerDeath")
        }
        onPlayerDeath()
    }

    private func destructiveRelease(instanceID: UUID, reason: String) async {
        doorObservation?.cancel()
        doorObservation = nil
        if let enemyID = prepared?.enemyID { onEnemyRemoved(enemyID) }
        prepared = nil
        do {
            try await door.closeForBattleAndUnloadPortal(ownerID: instanceID, reason: reason)
        } catch {
            door.releaseBattlePortal(ownerID: instanceID, reason: "\(reason).forced")
        }
        _ = try? await cleanup.releaseBattle(
            battleInstanceID: instanceID,
            reason: .battleCancelled,
            retentionPolicy: .remove,
            fullPortalReleased: !door.battlePortalFullExteriorResident,
            musicStillPlaying: false
        )
        if let battleLease {
            await arbiter.release(battleLease, reason: reason)
            self.battleLease = nil
        }
    }

    private func makeCue(
        _ cue: Chapter03BattleDefinition.RichCue,
        order: Int,
        battleInstanceID: UUID
    ) throws -> StoryBattleRichPrerecordingQueue.Cue {
        let descriptor = try prerecordingStore.descriptor(id: cue.prerecordingID)
        return StoryBattleRichPrerecordingQueue.Cue(
            cueID: cue.cueID,
            order: order,
            descriptor: descriptor,
            fileURL: try prerecordingStore.audioURL(for: descriptor),
            battleInstanceID: battleInstanceID,
            gainDB: cue.gainDB
        )
    }

    private func fail(chapterRunID: UUID, error: Error) async {
        await completionSink?.chapter03BikerBattleFailed(
            chapterRunID: chapterRunID,
            error: error
        )
    }

    private func clear() {
        chapterRunID = nil
        battleInstanceID = nil
        definition = nil
        recognitionCue = nil
        prepared = nil
        combat = nil
        musicEpoch = nil
        runTask = nil
        cleanupTask = nil
        handledDoorEvents.removeAll(keepingCapacity: false)
    }
}
