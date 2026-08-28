import Foundation
import RealityKit
import simd

struct Chapter03MikeBattleReleasedEvent {
    let eventID: UUID
    let chapterRunID: UUID
    let battleInstanceID: UUID
    let storyTransitionLease: StoryInteractionLease
    let blackoutRequestID: UUID
    let roomSuppressionReceipt: Chapter03RoomSuppressionReceipt
    let releaseReport: BattleRuntimeReleaseReport
    let doorState: TuringStoryDoorBattleState
    let richPrerecordingQueueDrained: Bool
    let activeBattleMusicHandleCount: Int
    let heavenBridgeDeathVocalToken: StoryPlayerDeathVocalToken

    var isSafeForHeaven: Bool {
        unsafeReasons.isEmpty
    }

    var unsafeReasons: [String] {
        var reasons: [String] = []
        if !releaseReport.allHeavyEnemyRuntimesReleased {
            reasons.append("enemy heavy runtime retained")
        }
        if !releaseReport.allEnemyControllersReleased {
            reasons.append("enemy controller retained")
        }
        if !releaseReport.fullPortalReleased {
            reasons.append("full door portal retained")
        }
        if releaseReport.musicStillPlaying {
            reasons.append("battle release report still owns music")
        }
        if doorState != .closed {
            reasons.append("door state is \(doorState.rawValue)")
        }
        if !richPrerecordingQueueDrained {
            reasons.append("Rich prerecording queue is not drained")
        }
        if activeBattleMusicHandleCount != 0 {
            reasons.append("\(activeBattleMusicHandleCount) battle music handles remain")
        }
        if !roomSuppressionReceipt.fullBlackConfirmed {
            reasons.append("room suppression did not confirm full black")
        }
        if blackoutRequestID != roomSuppressionReceipt.transitionID {
            reasons.append("blackout and room suppression IDs differ")
        }
        return reasons
    }
}

@MainActor
protocol Chapter03MikeBattleCompletionSink: AnyObject {
    func chapter03MikeBattleReleased(
        _ event: Chapter03MikeBattleReleasedEvent
    ) async throws
    func chapter03MikeBattleFailed(chapterRunID: UUID, error: Error) async
}

@MainActor
final class Chapter03MikeBattleCoordinator {
    private let definitionStore = Chapter03BattleDefinitionStore()
    private let prerecordingStore = TuringPrerecordingStore()
    private let enemyFactory: Chapter03BattleEnemyFactory
    private let door: any TuringStoryDoorBattleControlling
    private let arbiter: StoryInteractionArbiter
    private let clock: any BattleClock
    private let portalExitCleanup: StoryBattlePortalExitCleanupController
    private let intro: ScriptedPortalEnemyIntroCoordinator
    private let music: Chapter03BattleMusicController
    private let richQueue: StoryBattleRichPrerecordingQueue
    private let richVocalChannel: any StoryRichVocalChannelControlling
    private let registry = BattleEnemyRuntimeRegistry()
    private let cleanup: BattleRuntimeCleanupCoordinator
    private let roomPresentation: Chapter03RoomPresentationController
    private let onEnemyRemoved: @MainActor (UUID) -> Void
    private let playerTargetProvider: @MainActor () -> SIMD3<Float>?
    private let onPlayerContactFeedback: @MainActor (Int) -> Void
    private let onFinalAngelDeathSequenceBegan: @MainActor () -> Void
    private let onPlayerDeath: @MainActor () -> Void

    private weak var completionSink: (any Chapter03MikeBattleCompletionSink)?
    private weak var blackout: ImmersiveBlackoutController?
    private var chapterRunID: UUID?
    private var battleInstanceID: UUID?
    private var battleLease: StoryInteractionLease?
    private var definition: Chapter03BattleDefinition?
    private var prepared: ScriptedPortalPreparedEnemy?
    private var combat: Chapter03MikeBattleCombatAdapter?
    private var doorObservation: TuringStoryDoorBattleOpeningObservation?
    private var phaseOneEpoch: Chapter03BattleMusicEpoch?
    private var phaseTwoEpoch: Chapter03BattleMusicEpoch?
    private var recognitionCue: StoryBattleRichPrerecordingQueue.Cue?
    private var surrenderCue: StoryBattleRichPrerecordingQueue.Cue?
    private var handledDoorEvents = Set<UUID>()
    private var surrenderPlaybackID: UUID?
    private var latestPlayerTarget: SIMD3<Float>?
    private var runTask: Task<Void, Never>?
    private var defeatTask: Task<Void, Never>?
    private var crossfadeTask: Task<Void, Never>?
    private var suppressionReceipt: Chapter03RoomSuppressionReceipt?
    private var heavenBridgeDeathVocalToken: StoryPlayerDeathVocalToken?

    init(
        sceneRoot: Entity,
        door: any TuringStoryDoorBattleControlling,
        music: Chapter03BattleMusicController,
        roomPresentation: Chapter03RoomPresentationController,
        richVocalChannel: any StoryRichVocalChannelControlling,
        clock: any BattleClock = ProductionBattleClock(),
        arbiter: StoryInteractionArbiter = .shared,
        onEnemyPrepared: @escaping Chapter03BattleEnemyFactory.PreparedCallback,
        onEnemyRemoved: @escaping @MainActor (UUID) -> Void,
        playerTargetProvider: @escaping @MainActor () -> SIMD3<Float>?,
        onPlayerContactFeedback: @escaping @MainActor (Int) -> Void,
        onFinalAngelDeathSequenceBegan: @escaping @MainActor () -> Void,
        onPlayerDeath: @escaping @MainActor () -> Void
    ) {
        self.door = door
        self.music = music
        self.roomPresentation = roomPresentation
        self.richVocalChannel = richVocalChannel
        self.richQueue = StoryBattleRichPrerecordingQueue(
            richVocalChannel: richVocalChannel
        )
        self.clock = clock
        self.arbiter = arbiter
        self.portalExitCleanup = StoryBattlePortalExitCleanupController(
            door: door,
            clock: clock
        )
        self.intro = ScriptedPortalEnemyIntroCoordinator(clock: clock)
        self.enemyFactory = Chapter03BattleEnemyFactory(
            sceneRoot: sceneRoot,
            onPrepared: onEnemyPrepared
        )
        self.onEnemyRemoved = onEnemyRemoved
        self.playerTargetProvider = playerTargetProvider
        self.onPlayerContactFeedback = onPlayerContactFeedback
        self.onFinalAngelDeathSequenceBegan = onFinalAngelDeathSequenceBegan
        self.onPlayerDeath = onPlayerDeath
        self.cleanup = BattleRuntimeCleanupCoordinator(
            registry: registry,
            corpsePresenter: BattleCorpsePresentationController(storyRoot: sceneRoot)
        )
        richQueue.onActualPlaybackStarted = { [weak self] event in
            self?.prerecordingActuallyStarted(event)
        }
    }

    func bind(blackout: ImmersiveBlackoutController) {
        self.blackout = blackout
    }

    func prepareAndStart(
        chapterRunID: UUID,
        battleInstanceID: UUID,
        battleLease: StoryInteractionLease,
        completionSink: any Chapter03MikeBattleCompletionSink,
        startImmediately: Bool = true
    ) async throws {
        guard let blackout else {
            throw StoryTitleCardError.missingPresentationOwner
        }
        _ = blackout
        try await arbiter.requireCurrent(battleLease)
        try richVocalChannel.requirePlayerDeathVocalResources()
        let definition = try definitionStore.load(.mike)
        try music.prepare(definition: definition)
        let recognition = try makeCue(
            definition.richCues[0],
            order: 0,
            battleInstanceID: battleInstanceID
        )
        let surrender = try makeCue(
            definition.richCues[1],
            order: 1,
            battleInstanceID: battleInstanceID
        )
        richQueue.reserve(recognition)
        richQueue.reserve(surrender)
        self.chapterRunID = chapterRunID
        self.battleInstanceID = battleInstanceID
        self.battleLease = battleLease
        self.completionSink = completionSink
        self.definition = definition
        recognitionCue = recognition
        surrenderCue = surrender

        try await door.acquireBattlePortal(
            ownerID: battleInstanceID,
            reason: "chapter03.mike.prepare"
        )
        try await arbiter.setBattleDoorPermission(
            .playerMayOpen,
            battleLease: battleLease,
            reason: "chapter03.mike.portalApproach"
        )
        doorObservation = door.observeBattleDoorOpening(
            ownerID: battleInstanceID
        ) { [weak self] event in
            self?.handleDoorOpening(event)
        }
        let context = try door.battlePortalContext()
        let enemy = try await enemyFactory.prepareMike(
            definition: definition,
            doorContext: context,
            battleInstanceID: battleInstanceID
        )
        try registry.register(
            BattleEnemyRuntimeLease(
                identity: enemy.sourceController.battleRuntimeIdentity,
                controller: enemy.sourceController,
                portalMirror: enemy.portalMirror
            )
        )
        prepared = enemy
        intro.install(
            prepared: enemy,
            doorContext: context,
            configuration: ScriptedPortalEnemyIntroConfiguration(
                idleDurationSeconds: definition.enemy.idleDurationSeconds,
                turnCount: definition.enemy.turnCount,
                turnDegreesPerCompletion: definition.enemy.turnDegreesPerCompletion,
                revealThresholdPortalLocalZMeters: 0.02,
                exitThresholdPortalLocalZMeters: 0.08
            ),
            onInitialIdleStarted: { [weak self] in
                guard let self, self.battleInstanceID == battleInstanceID else {
                    throw CancellationError()
                }
                let eventID = UUID()
                self.phaseOneEpoch = try self.music.start(
                    lane: .bigMikePhaseOne,
                    battleInstanceID: battleInstanceID,
                    triggerEventID: eventID
                )
                print(
                    "[Chapter03MikeBattle] portal source visible initial idle started battleInstanceID=\(battleInstanceID.uuidString) eventID=\(eventID.uuidString)"
                )
            },
            onStateChange: { _ in }
        )
        if startImmediately {
            try beginPreparedOpening()
        }
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
        defeatTask?.cancel()
        crossfadeTask?.cancel()
        runTask = nil
        defeatTask = nil
        crossfadeTask = nil
        doorObservation?.cancel()
        doorObservation = nil
        richQueue.cancel(battleInstanceID: instanceID, reason: reason)
        stopOwnedHeavenBridgeDeathVocal(reason: "cancel.\(reason)")
        if blackout?.blackoutOpacity == 1 {
            combat?.releaseUnderFullBlack(reason: reason)
        } else {
            // Cancellation is a teardown boundary, not Mike's authored defeat.
            combat?.stopUnderFullBlack(reason: "cancel.\(reason)")
            combat?.releaseUnderFullBlack(reason: reason)
        }
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
                reason: "chapter03.mike.arrivedA3"
            )
            door.setBattleInteractionLocked(
                true,
                ownerID: battleInstanceID,
                reason: "chapter03.mike.arrivedA3"
            )
            if door.battleDoorState != .open {
                try prepared.sourceController.playScriptedIdleLoop()
                try await door.openForBattle(
                    ownerID: battleInstanceID,
                    reason: "chapter03.mike.autoOpenAtA3"
                )
            }
            try await intro.performPortalCrossing()
            try Task.checkCancellation()
            guard self.chapterRunID == chapterRunID,
                  self.battleInstanceID == battleInstanceID else {
                throw Chapter03Error.staleRun
            }
            portalExitCleanup.scheduleAfterPortalExit(
                ownerID: battleInstanceID,
                reason: "chapter03.mike.mikeExited"
            )
            let combat = Chapter03MikeBattleCombatAdapter(
                confirmedHitsToKill: definition.playerConfirmedHitsToKill
            )
            self.combat = combat
            try combat.activate(
                enemy: prepared.sourceController,
                context: Chapter03MikeCombatContext(
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
                    onNonlethalDefeatThreshold: { [weak self] snapshot in
                        self?.handleThreshold(
                            chapterRunID: chapterRunID,
                            battleInstanceID: battleInstanceID,
                            snapshot: snapshot
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
              let recognitionCue,
              let battleInstanceID else { return }
        richQueue.releaseReservationAndEnqueue(
            cueID: recognitionCue.cueID,
            battleInstanceID: battleInstanceID
        )
    }

    private func handleThreshold(
        chapterRunID: UUID,
        battleInstanceID: UUID,
        snapshot: StoryEnemyAcceptedDamageSnapshot
    ) {
        guard defeatTask == nil,
              snapshot.remainingAcceptedDamagePoints == 0,
              !snapshot.isLethal,
              let surrenderCue else { return }
        onFinalAngelDeathSequenceBegan()
        print(
            "[Chapter03MikeBattle] nonlethal threshold claimed accepted=\(snapshot.acceptedHitCount)/\(snapshot.acceptedHitCapacity) deathAnimationRequested=false"
        )
        defeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.richQueue.enqueueAndWait(surrenderCue)
                let deathToken = try self.richVocalChannel
                    .startRandomPlayerDeathVocal(
                        purpose: .chapter03TunnelBridge,
                        ownerID:
                            "chapter03.mike.heaven.\(battleInstanceID.uuidString)"
                    )
                self.heavenBridgeDeathVocalToken = deathToken
                print(
                    "[Chapter03DeathBridge] started after final Rich PR " +
                        "battleInstanceID=\(battleInstanceID.uuidString) " +
                        "file=\(deathToken.fileName) " +
                        "duration=\(deathToken.durationSeconds)"
                )
                try await self.clock.sleep(
                    for: .seconds(
                        self.definition?.postSurrenderPrerecordingBeatSeconds ?? 1
                    )
                )
                try await self.finishAfterSurrender(
                    chapterRunID: chapterRunID,
                    battleInstanceID: battleInstanceID
                )
            } catch {
                await self.fail(chapterRunID: chapterRunID, error: error)
            }
        }
    }

    private func prerecordingActuallyStarted(
        _ event: StoryBattlePrerecordingStartedEvent
    ) {
        guard event.battleInstanceID == battleInstanceID,
              event.cueID == "mikeSurrender",
              surrenderPlaybackID == nil,
              let battleInstanceID else { return }
        surrenderPlaybackID = event.playbackID
        do {
            let transition = try music.beginCrossfade(
                from: phaseOneEpoch,
                to: .bigMikePhaseTwo,
                battleInstanceID: battleInstanceID,
                triggerEventID: event.playbackID,
                durationSeconds:
                    definition?.surrenderMusicCrossfadeSeconds ?? 1.5
            )
            phaseTwoEpoch = transition.incomingEpoch
            crossfadeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    self.phaseTwoEpoch = try await self.music
                        .completeCrossfade(transition)
                } catch is CancellationError {
                } catch {
                    guard let chapterRunID = self.chapterRunID else {
                        return
                    }
                    await self.fail(
                        chapterRunID: chapterRunID,
                        error: error
                    )
                }
            }
        } catch {
            crossfadeTask = Task { @MainActor [weak self] in
                guard let self,
                      let chapterRunID = self.chapterRunID else { return }
                await self.fail(
                    chapterRunID: chapterRunID,
                    error: error
                )
            }
        }
    }

    private func finishAfterSurrender(
        chapterRunID: UUID,
        battleInstanceID: UUID
    ) async throws {
        guard let blackout, let definition, let battleLease else {
            throw Chapter03Error.staleRun
        }
        guard let heavenBridgeDeathVocalToken else {
            throw Chapter03Error.definitionInvalid(
                "The Mike-to-Heaven death-vocal bridge did not start."
            )
        }
        let transitionID = UUID()
        async let scoreFade: Void = music.fadeOutAndStopAll(
            battleInstanceID: battleInstanceID,
            durationSeconds: definition.fadeToBlackSeconds,
            reason: "chapter03.mike.heavenBlackout"
        )
        try await blackout.fadeToFullBlack(
            duration: .seconds(definition.fadeToBlackSeconds),
            requestID: transitionID
        )
        await scoreFade
        try blackout.requireFullBlackOwnership(requestID: transitionID)

        // Rich PR 2 has completed before this method is entered. From here on,
        // every visible release happens under complete black.
        combat?.releaseUnderFullBlack(reason: "chapter03.mike.fullBlack")
        combat = nil
        intro.cancelAndRelease(reason: "chapter03.mike.fullBlack")
        doorObservation?.cancel()
        doorObservation = nil
        crossfadeTask?.cancel()
        crossfadeTask = nil
        richQueue.cancel(battleInstanceID: battleInstanceID, reason: "fullBlackCompleted")
        music.stopAll(reason: "fullBlackCompleted")
        if let enemyID = prepared?.enemyID {
            onEnemyRemoved(enemyID)
        }
        prepared = nil
        try await portalExitCleanup.closeAndUnloadNowIfNeeded(
            ownerID: battleInstanceID,
            reason: "chapter03.mike.fullBlack"
        )
        let releaseReport = try await cleanup.releaseBattle(
            battleInstanceID: battleInstanceID,
            reason: .battleCompleted,
            retentionPolicy: .remove,
            fullPortalReleased: !door.battlePortalFullExteriorResident,
            musicStillPlaying: music.activeHandleCount > 0
        )
        let receipt = try roomPresentation.suppressUnderFullBlack(
            transitionID: transitionID
        )
        suppressionReceipt = receipt
        let transitionLease = try await arbiter.transferBattleToStoryTransition(
            battleLease: battleLease,
            transitionID: transitionID,
            reason: "chapter03MikeDefeatToHeaven"
        )
        self.battleLease = nil
        guard let completionSink else {
            throw Chapter03Error.staleRun
        }
        let releaseEvent = Chapter03MikeBattleReleasedEvent(
            eventID: UUID(),
            chapterRunID: chapterRunID,
            battleInstanceID: battleInstanceID,
            storyTransitionLease: transitionLease,
            blackoutRequestID: transitionID,
            roomSuppressionReceipt: receipt,
            releaseReport: releaseReport,
            doorState: door.battleDoorState,
            richPrerecordingQueueDrained:
                richQueue.isDrained(battleInstanceID: battleInstanceID),
            activeBattleMusicHandleCount: music.activeHandleCount,
            heavenBridgeDeathVocalToken: heavenBridgeDeathVocalToken
        )
        print(
            "[Chapter03Transition] Mike release audited " +
                "battleInstanceID=\(battleInstanceID.uuidString) " +
                "safe=\(releaseEvent.isSafeForHeaven) " +
                "unsafeReasons=\(releaseEvent.unsafeReasons)"
        )
        guard releaseEvent.isSafeForHeaven else {
            throw Chapter03Error.definitionInvalid(
                "Mike runtime was not fully released before the Heaven tunnel handoff: " +
                    releaseEvent.unsafeReasons.joined(separator: ", ")
            )
        }
        try await completionSink.chapter03MikeBattleReleased(
            releaseEvent
        )
        self.heavenBridgeDeathVocalToken = nil
        clear()
    }

    private func handlePlayerDeath(battleInstanceID: UUID) {
        guard self.battleInstanceID == battleInstanceID,
              combat?.postDefeatMode == false else { return }
        richQueue.cancel(battleInstanceID: battleInstanceID, reason: "playerDeath")
        music.stopAll(reason: "playerDeath")
        Task { @MainActor [weak self] in
            await self?.destructiveRelease(instanceID: battleInstanceID, reason: "playerDeath")
        }
        onPlayerDeath()
    }

    private func destructiveRelease(instanceID: UUID, reason: String) async {
        doorObservation?.cancel()
        doorObservation = nil
        intro.cancelAndRelease(reason: reason)
        if let enemyID = prepared?.enemyID { onEnemyRemoved(enemyID) }
        prepared = nil
        do {
            try await portalExitCleanup.closeAndUnloadNowIfNeeded(
                ownerID: instanceID,
                reason: reason
            )
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
        stopOwnedHeavenBridgeDeathVocal(reason: "failure.\(error.localizedDescription)")
        await completionSink?.chapter03MikeBattleFailed(
            chapterRunID: chapterRunID,
            error: error
        )
    }

    private func clear() {
        chapterRunID = nil
        battleInstanceID = nil
        definition = nil
        prepared = nil
        combat = nil
        recognitionCue = nil
        surrenderCue = nil
        phaseOneEpoch = nil
        phaseTwoEpoch = nil
        surrenderPlaybackID = nil
        runTask = nil
        defeatTask = nil
        crossfadeTask = nil
        handledDoorEvents.removeAll(keepingCapacity: false)
    }

    private func stopOwnedHeavenBridgeDeathVocal(reason: String) {
        guard let heavenBridgeDeathVocalToken else { return }
        richVocalChannel.stopPlayerDeathVocal(
            token: heavenBridgeDeathVocalToken,
            reason: reason
        )
        self.heavenBridgeDeathVocalToken = nil
    }
}
