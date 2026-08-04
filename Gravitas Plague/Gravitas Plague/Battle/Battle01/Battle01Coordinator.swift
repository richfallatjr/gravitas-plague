import Foundation
import RealityKit
import simd

struct Battle01MusicStartGate: Equatable {
    private(set) var scriptPoint03TTSCompleted = false
    private(set) var startClaimed = false

    mutating func recordScriptPoint03TTSCompletion() {
        scriptPoint03TTSCompleted = true
    }

    mutating func claimIfEligible(
        doorState: TuringStoryDoorBattleState,
        mediaPrepared: Bool
    ) -> Bool {
        guard scriptPoint03TTSCompleted,
              doorState == .open,
              mediaPrepared,
              !startClaimed else {
            return false
        }
        startClaimed = true
        return true
    }
}

@MainActor
final class Battle01Coordinator {
    typealias EnemyPreparedHook = @MainActor (UUID, JockRetargetTestController) -> Void
    typealias EnemyRemovedHook = @MainActor (UUID) -> Void
    typealias EnemyMemoryPresenceHook = @MainActor (Bool, String) -> Void
    typealias PostBattleHoldHook = @MainActor (BattleRuntimeReleasedEvent) async -> Void

    private let definitionStore = Battle01DefinitionStore()
    private let enemyFactory: Battle01EnemyFactory
    private let door: any TuringStoryDoorBattleControlling
    private let intro: ScriptedPortalEnemyIntroCoordinator
    private let combat: any Battle01StoryCombatControlling
    private let soundtrack: any Battle01SoundtrackControlling
    private let richPR: any Battle01RichPrerecordingPlaying
    private let enemyRegistry: BattleEnemyRuntimeRegistry
    private let corpsePresenter: BattleCorpsePresentationController
    private let runtimeCleanup: BattleRuntimeCleanupCoordinator
    private let prerecordingStore = TuringPrerecordingStore()
    private let clock: any BattleClock
    private let onEnemyRemoved: EnemyRemovedHook
    private let onEnemyMemoryPresenceChanged: EnemyMemoryPresenceHook
    private let onPostBattleHold: PostBattleHoldHook
    private let playerTargetProvider: @MainActor () -> SIMD3<Float>?
    private let onPlayerDamage: @MainActor (Float) -> Void

    private struct SoundtrackStartContext {
        let definition: Battle01Definition
        let soundtrackURL: URL
        let richDescriptor: TuringPrerecordingDescriptor
        let richURL: URL
    }

    private(set) var state: Battle01State = .unloaded
    private var battleInstanceID: UUID?
    private var interactionLease: StoryInteractionLease?
    private var startTask: Task<Void, Never>?
    private var richPRTask: Task<Void, Never>?
    private var aftermathTransitionTask: Task<Void, Never>?
    private var runtimeCleanupTask: Task<Void, Never>?
    private var prepared: Battle01PreparedEnemy?
    private var soundtrackStarted = false
    private var aftermathLoopStarted = false
    private var musicStartGate = Battle01MusicStartGate()
    private var soundtrackStartContext: SoundtrackStartContext?
    private var portalCrossingStarted = false
    private var latestPlayerTarget: SIMD3<Float>?
    private var enemyMemoryPresenceAnnounced = false
    private var runtimeReleaseWaiters:
        [UUID: CheckedContinuation<Void, Never>] = [:]

    var hasActiveBattleRuntime: Bool {
        let registeredEnemyPresent = battleInstanceID.map {
            enemyRegistry.activeEnemyCount(battleInstanceID: $0) > 0
        } ?? false
        return enemyMemoryPresenceAnnounced ||
            registeredEnemyPresent ||
            door.battlePortalFullExteriorResident
    }

    func waitUntilRuntimeReleased() async {
        guard hasActiveBattleRuntime else { return }
        let waiterID = UUID()
        await withCheckedContinuation { continuation in
            runtimeReleaseWaiters[waiterID] = continuation
        }
    }

    init(
        sceneRoot: Entity,
        door: any TuringStoryDoorBattleControlling,
        clock: any BattleClock,
        onEnemyPrepared: @escaping EnemyPreparedHook,
        onEnemyRemoved: @escaping EnemyRemovedHook,
        onEnemyMemoryPresenceChanged: @escaping EnemyMemoryPresenceHook,
        onPostBattleHold: @escaping PostBattleHoldHook = { _ in },
        playerTargetProvider: @escaping @MainActor () -> SIMD3<Float>?,
        onPlayerDamage: @escaping @MainActor (Float) -> Void
    ) {
        self.door = door
        self.clock = clock
        self.intro = ScriptedPortalEnemyIntroCoordinator(clock: clock)
        self.combat = Battle01StoryCombatAdapter()
        self.soundtrack = Battle01SoundtrackController()
        self.richPR = Battle01RichPrerecordingController()
        let enemyRegistry = BattleEnemyRuntimeRegistry()
        let corpsePresenter = BattleCorpsePresentationController(storyRoot: sceneRoot)
        self.enemyRegistry = enemyRegistry
        self.corpsePresenter = corpsePresenter
        self.runtimeCleanup = BattleRuntimeCleanupCoordinator(
            registry: enemyRegistry,
            corpsePresenter: corpsePresenter
        )
        self.enemyFactory = Battle01EnemyFactory(
            sceneRoot: sceneRoot,
            onPrepared: onEnemyPrepared
        )
        self.onEnemyRemoved = onEnemyRemoved
        self.onEnemyMemoryPresenceChanged = onEnemyMemoryPresenceChanged
        self.onPostBattleHold = onPostBattleHold
        self.playerTargetProvider = playerTargetProvider
        self.onPlayerDamage = onPlayerDamage
    }

    func start(
        trigger: Battle01Trigger,
        instanceID: UUID,
        interactionLease: StoryInteractionLease
    ) {
        guard state == .unloaded,
              battleInstanceID == nil else {
            print("[Battle01] duplicate trigger ignored state=\(state.rawValue)")
            return
        }

        guard interactionLease.owner == .battle(
            battleInstanceID: instanceID
        ) else {
            print("[Battle01] rejected mismatched Story interaction lease")
            Task {
                await StoryInteractionArbiter.shared.release(
                    interactionLease,
                    reason: "battleStartLeaseMismatch"
                )
            }
            return
        }
        runtimeCleanupTask?.cancel()
        runtimeCleanupTask = nil
        battleInstanceID = instanceID
        self.interactionLease = interactionLease
        state = .preparing
        switch trigger {
        case .scriptPointCompleted(let event):
            guard event.scriptPointID == "prologue.scriptPoint03" else {
                battleInstanceID = nil
                self.interactionLease = nil
                state = .unloaded
                print("[Battle01] rejected non-ScriptPoint03 trigger scriptPointID=\(event.scriptPointID)")
                Task {
                    await StoryInteractionArbiter.shared.release(
                        interactionLease,
                        reason: "invalidBattleTrigger"
                    )
                }
                return
            }
            musicStartGate.recordScriptPoint03TTSCompletion()
        case .continuationRestore(let sourceEventID):
            musicStartGate.recordScriptPoint03TTSCompletion()
            print("[Battle01] continuation trigger sourceEventID=\(sourceEventID.uuidString)")
        case .debug:
            musicStartGate.recordScriptPoint03TTSCompletion()
            print("[Battle01MusicGate] debug trigger simulates ScriptPoint03 TTS completion")
        }
        Battle01EventLog.emit(
            "triggered after ScriptPoint03",
            instanceID: instanceID,
            state: state
        )
        setEnemyMemoryPresence(
            true,
            reason: "battleStartBeforeGrandmaAllocation"
        )

        let gateState = TuringFlowInteractionGateController.shared.state
        print("""
        [TuringFlowGate] state remains microphone
          state: \(gateState.rawValue)
          owner: none
          changedByBattle01: false
        """)

        startTask = Task { @MainActor [weak self] in
            await self?.run(instanceID: instanceID, trigger: trigger)
        }
    }

    func update(
        deltaTime: TimeInterval,
        playerTargetWorldPosition: SIMD3<Float>?
    ) {
        latestPlayerTarget = playerTargetWorldPosition
        prepared?.portalMirror.refreshPortalLightingIfNeeded()
        tryStartSoundtrackIfEligible(reason: "doorStateObserved")
        switch state {
        case .portalIdleFacingAway, .turnOne, .turnTwo, .approachingDoor,
             .waitingForDoor, .openingDoor, .portalCrossing:
            intro.update(deltaTime: deltaTime)
        case .combat:
            combat.update(deltaTime: deltaTime)
        default:
            break
        }
    }

    func cancel(reason: String) {
        guard state != .unloaded else { return }
        state = .cancelled
        let cancelledInstanceID = battleInstanceID
        let cancelledEnemyID = prepared?.enemyID
        startTask?.cancel()
        richPRTask?.cancel()
        aftermathTransitionTask?.cancel()
        runtimeCleanupTask?.cancel()
        soundtrack.stop(reason: reason)
        richPR.cancel(reason: reason)
        combat.cancelAndRelease(reason: reason)
        intro.cancelAndRelease(reason: reason)
        prepared = nil

        if let instanceID = cancelledInstanceID {
            Battle01EventLog.emit(
                "cancelled",
                instanceID: instanceID,
                state: state,
                fields: [("reason", reason)]
            )
        }

        if let cancelledEnemyID {
            onEnemyRemoved(cancelledEnemyID)
        }
        if let instanceID = cancelledInstanceID {
            runtimeCleanupTask = Task { @MainActor [weak self] in
                await self?.releaseCancelledRuntime(
                    instanceID: instanceID,
                    reason: reason
                )
            }
        }
        battleInstanceID = nil
        startTask = nil
        richPRTask = nil
        aftermathTransitionTask = nil
        soundtrackStarted = false
        aftermathLoopStarted = false
        musicStartGate = Battle01MusicStartGate()
        soundtrackStartContext = nil
        portalCrossingStarted = false
        latestPlayerTarget = nil
        state = .unloaded
    }

    private func run(instanceID: UUID, trigger: Battle01Trigger) async {
        do {
            let definition = try definitionStore.load()
            try await door.acquireBattlePortal(
                ownerID: instanceID,
                reason: "enemyAnimationPresent"
            )
            let doorContext = try door.battlePortalContext()
            let soundtrackURL = try definitionStore.soundtrackURL(for: definition)
            let aftermathSoundtrackURL = try definitionStore.aftermathSoundtrackURL(
                for: definition
            )
            let richDescriptor = try prerecordingStore.descriptor(
                id: definition.richPrerecording.prerecordingID
            )
            let richURL = try prerecordingStore.audioURL(for: richDescriptor)
            try soundtrack.prepare(fileURL: soundtrackURL)
            try soundtrack.prepareAftermathLoop(fileURL: aftermathSoundtrackURL)
            soundtrackStartContext = SoundtrackStartContext(
                definition: definition,
                soundtrackURL: soundtrackURL,
                richDescriptor: richDescriptor,
                richURL: richURL
            )
            tryStartSoundtrackIfEligible(reason: "battleMediaPrepared")
            guard state != .failed,
                  battleInstanceID == instanceID else { return }

            Battle01EventLog.emit(
                "anchors resolved",
                instanceID: instanceID,
                state: state,
                fields: [
                    ("a1", String(describing: doorContext.zombieA1.position(relativeTo: nil))),
                    ("a2", String(describing: doorContext.zombieA2.position(relativeTo: nil))),
                    ("a3", String(describing: doorContext.zombieA3.position(relativeTo: nil)))
                ]
            )

            let enemy = try await enemyFactory.prepare(
                definition: definition,
                doorContext: doorContext,
                battleInstanceID: instanceID
            )
            guard Task.isCancelled == false,
                  battleInstanceID == instanceID else {
                await releaseUnregisteredPreparedEnemy(
                    enemy,
                    reason: "cancelledBeforeRegistryOwnership"
                )
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
                await releaseUnregisteredPreparedEnemy(
                    enemy,
                    lease: enemyLease,
                    reason: "registryRejected"
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
                    turnDegreesPerCompletion: definition.enemy.turnDegreesPerCompletion,
                    revealThresholdPortalLocalZMeters:
                        definition.portalHandoff.revealThresholdPortalLocalZMeters,
                    exitThresholdPortalLocalZMeters:
                        definition.portalHandoff.exitThresholdPortalLocalZMeters
                )
            ) { [weak self] nextState in
                guard self?.battleInstanceID == instanceID else { return }
                switch nextState {
                case .portalIdleFacingAway:
                    self?.state = .portalIdleFacingAway
                case .turnOne:
                    self?.state = .turnOne
                case .turnTwo:
                    self?.state = .turnTwo
                case .approachingDoor:
                    self?.state = .approachingDoor
                case .portalCrossing:
                    self?.state = .portalCrossing
                }
            }

            try await intro.performApproach()
            try Task.checkCancellation()
            guard battleInstanceID == instanceID else { return }

            door.setBattleInteractionLocked(
                true,
                ownerID: instanceID,
                reason: "grandmaAtA3"
            )
            if door.battleDoorState != .open {
                state = door.battleDoorState == .closed ? .openingDoor : .waitingForDoor
                try enemy.sourceController.playScriptedIdleLoop()
                Battle01EventLog.emit(
                    "door open started",
                    instanceID: instanceID,
                    state: state,
                    fields: [("doorState", door.battleDoorState.rawValue)]
                )
                try await door.openForBattle(
                    ownerID: instanceID,
                    reason: "grandmaPush"
                )
                Battle01EventLog.emit(
                    "door open completed",
                    instanceID: instanceID,
                    state: state
                )
            }
            tryStartSoundtrackIfEligible(reason: "doorOpenCompleted")
            guard state != .failed,
                  battleInstanceID == instanceID else { return }

            portalCrossingStarted = true
            try await intro.performPortalCrossing()
            try Task.checkCancellation()
            guard battleInstanceID == instanceID else { return }

            print("""
            [TuringDoorPortal] battle lease retained through combat
              ownerID: \(instanceID.uuidString)
              releaseBoundary: closeAnimationAndSFXCompletion
            """)

            state = .combat
            try combat.activate(
                enemy: enemy.sourceController,
                context: StoryEnemyCombatContext(
                    battleInstanceID: instanceID,
                    playerTargetProvider: { [weak self] in
                        guard let self else { return nil }
                        return self.latestPlayerTarget ?? self.playerTargetProvider()
                    },
                    onPlayerDamage: { [weak self] amount in
                        self?.onPlayerDamage(amount)
                    },
                    onEnemyDeathStarted: { [weak self] in
                        guard self?.battleInstanceID == instanceID else { return }
                        Battle01EventLog.emit(
                            "Grandma death started",
                            instanceID: instanceID,
                            state: .combat
                        )
                    },
                    onEnemyDeathAnimationCompleted: { [weak self] in
                        guard let self,
                              self.battleInstanceID == instanceID else { return }
                        self.state = .grandmaDown
                        Battle01EventLog.emit(
                            "Grandma death completed",
                            instanceID: instanceID,
                            state: self.state
                        )
                        self.scheduleAftermathTransition(
                            instanceID: instanceID,
                            configuration: definition.aftermathMusic
                        )
                        self.state = .releasingBattleRuntime
                        self.scheduleRuntimeCleanup(
                            instanceID: instanceID,
                            enemyID: enemy.enemyID
                        )
                    }
                )
            )
            startTask = nil
        } catch is CancellationError {
            if battleInstanceID == instanceID {
                cancel(reason: "runTaskCancelled")
            }
        } catch {
            fail(error, instanceID: instanceID)
        }
    }

    private func scheduleAftermathTransition(
        instanceID: UUID,
        configuration: Battle01Definition.AftermathMusic
    ) {
        guard aftermathTransitionTask == nil,
              !aftermathLoopStarted else { return }

        let minimumDelay = min(
            configuration.delayAfterGrandmaDeathMinSeconds,
            configuration.delayAfterGrandmaDeathMaxSeconds
        )
        let maximumDelay = max(
            configuration.delayAfterGrandmaDeathMinSeconds,
            configuration.delayAfterGrandmaDeathMaxSeconds
        )
        let delay = Double.random(in: minimumDelay...maximumDelay)

        Battle01EventLog.emit(
            "aftermath crossfade scheduled",
            instanceID: instanceID,
            state: state,
            fields: [
                ("delaySeconds", String(format: "%.3f", delay)),
                ("delayRangeSeconds", "\(minimumDelay)...\(maximumDelay)"),
                ("targetDecibels", String(configuration.targetDecibels)),
                ("fadeDurationSeconds", String(configuration.crossfadeDurationSeconds))
            ]
        )

        aftermathTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: .seconds(delay))
                try Task.checkCancellation()
                guard self.battleInstanceID == instanceID else { return }

                try await self.soundtrack.transferToAftermathLoop(
                    battleInstanceID: instanceID,
                    targetDecibels: configuration.targetDecibels,
                    fadeDurationSeconds: configuration.crossfadeDurationSeconds
                ) { [weak self] returnedID in
                    guard let self,
                          returnedID == instanceID,
                          self.battleInstanceID == instanceID else { return }
                    self.aftermathLoopStarted = true
                    Battle01EventLog.emit(
                        "aftermath loop started",
                        instanceID: instanceID,
                        state: self.state,
                        fields: [
                            ("file", configuration.file),
                            ("targetDecibels", String(configuration.targetDecibels)),
                            ("loop", "true"),
                            ("stop", configuration.stop)
                        ]
                    )
                }
                self.aftermathTransitionTask = nil
            } catch is CancellationError {
                return
            } catch {
                self.aftermathTransitionTask = nil
                Battle01EventLog.emit(
                    "aftermath crossfade failed",
                    instanceID: instanceID,
                    state: self.state,
                    fields: [("error", error.localizedDescription)]
                )
            }
        }
    }

    private func scheduleRuntimeCleanup(
        instanceID: UUID,
        enemyID: UUID
    ) {
        runtimeCleanupTask?.cancel()
        Battle01EventLog.emit(
            "battle runtime cleanup scheduled",
            instanceID: instanceID,
            state: state,
            fields: [
                ("enemyID", enemyID.uuidString),
                ("delaySeconds", "0"),
                ("startsAtActualDeathAnimationCompletion", "true")
            ]
        )

        runtimeCleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard self.battleInstanceID == instanceID else { return }

                let beforeRelease = BattleRuntimeMemorySnapshot.capture(
                    label: "beforeBattle01RuntimeTeardown"
                )

                self.richPRTask?.cancel()
                self.richPRTask = nil
                self.richPR.cancel(reason: "Battle01.deathCleanup")
                self.combat.cancelAndRelease(reason: "Battle01.deathCleanup")
                self.intro.cancelAndRelease(reason: "Battle01.deathCleanup")
                self.prepared = nil
                self.onEnemyRemoved(enemyID)

                let enemyResult = try await self.runtimeCleanup.releaseEnemy(
                    battleInstanceID: instanceID,
                    enemyID: enemyID,
                    reason: .neutralized,
                    retentionPolicy: .remove
                )
                Battle01EventLog.emit(
                    "final enemy released",
                    instanceID: instanceID,
                    state: self.state,
                    fields: [
                        ("enemyID", enemyID.uuidString),
                        ("heavyRuntimeReleased", String(enemyResult.heavyRuntimeReleased)),
                        ("preparedClipCount", String(enemyResult.releasedPreparedClipCount)),
                        ("remainingEnemyLeaseCount", "0"),
                        ("doorCloseWaitedForEnemyRelease", "true")
                    ]
                )

                Battle01EventLog.emit(
                    "door close requested before exterior teardown",
                    instanceID: instanceID,
                    state: self.state,
                    fields: [
                        ("doorState", self.door.battleDoorState.rawValue),
                        ("requiresAnimationCompletion", "true"),
                        ("requiresSFXCompletion", "true")
                    ]
                )
                let doorCloseTask = Task { @MainActor [door = self.door] in
                    try await door.closeForBattleAndUnloadPortal(
                        ownerID: instanceID,
                        reason: "finalEnemyRuntimeReleased"
                    )
                }
                if let aftermathTransitionTask = self.aftermathTransitionTask {
                    await aftermathTransitionTask.value
                }
                try Task.checkCancellation()
                do {
                    try await doorCloseTask.value
                } catch {
                    let aftermathPlaying =
                        await StoryAftermathMusicActor.shared.isPlaying()
                    let musicStillPlaying =
                        self.soundtrack.isPlaying || aftermathPlaying
                    _ = try? await self.runtimeCleanup.releaseBattle(
                        battleInstanceID: instanceID,
                        reason: .battleCompleted,
                        retentionPolicy: .remove,
                        fullPortalReleased: false,
                        musicStillPlaying: musicStillPlaying,
                        beforeSnapshot: beforeRelease
                    )
                    throw error
                }
                try Task.checkCancellation()
                _ = BattleRuntimeMemorySnapshot.capture(
                    label: "afterBattle01FullPortalReleased"
                )
                let aftermathPlaying =
                    await StoryAftermathMusicActor.shared.isPlaying()
                let musicStillPlaying =
                    self.soundtrack.isPlaying || aftermathPlaying
                let report = try await self.runtimeCleanup.releaseBattle(
                    battleInstanceID: instanceID,
                    reason: .battleCompleted,
                    retentionPolicy: .remove,
                    fullPortalReleased: !self.door.battlePortalFullExteriorResident,
                    musicStillPlaying: musicStillPlaying,
                    beforeSnapshot: beforeRelease
                )

                self.door.setBattleInteractionLocked(
                    false,
                    ownerID: instanceID,
                    reason: "battleRuntimeReleased"
                )
                self.startTask = nil
                self.richPRTask?.cancel()
                self.richPRTask = nil
                self.soundtrackStartContext = nil
                self.portalCrossingStarted = false
                self.latestPlayerTarget = nil
                self.soundtrackStarted = false
                self.state = .postBattleAudioOnly
                self.setEnemyMemoryPresence(
                    false,
                    reason: "battleRuntimeReleased"
                )

                let event = BattleRuntimeReleasedEvent(
                    eventID: UUID(),
                    battleInstanceID: instanceID,
                    releaseReport: report
                )
                Battle01EventLog.emit(
                    "BattleRuntimeReleasedEvent",
                    instanceID: instanceID,
                    state: self.state,
                    fields: [
                        ("enemyRegistryCount", "0"),
                        ("fullPortalResident", String(self.door.battlePortalFullExteriorResident)),
                        ("musicStillPlaying", String(musicStillPlaying))
                    ]
                )
                await self.onPostBattleHold(event)
                await self.releaseInteractionLease(
                    reason: "battleRuntimeReleased"
                )
                self.resumeRuntimeReleaseWaiters()
                self.runtimeCleanupTask = nil
            } catch is CancellationError {
                return
            } catch {
                self.runtimeCleanupTask = nil
                self.state = .failed
                Battle01EventLog.emit(
                    "battle runtime cleanup failed",
                    instanceID: instanceID,
                    state: self.state,
                    fields: [("error", error.localizedDescription)]
                )
                self.cancel(
                    reason: "runtimeCleanupFailure.\(error.localizedDescription)"
                )
            }
        }
    }

    private func releaseCancelledRuntime(
        instanceID: UUID,
        reason: String
    ) async {
        await StoryAftermathMusicActor.shared.stop(reason: "battleCancelled.\(reason)")
        do {
            try await door.closeForBattleAndUnloadPortal(
                ownerID: instanceID,
                reason: "cancel.\(reason)"
            )
        } catch {
            door.releaseBattlePortal(ownerID: instanceID, reason: "cancelCloseFailure.\(reason)")
            print("[BattleRuntimeCleanup] cancellation door close failed error=\(error.localizedDescription)")
        }
        do {
            _ = try await runtimeCleanup.releaseBattle(
                battleInstanceID: instanceID,
                reason: .battleCancelled,
                retentionPolicy: .remove,
                fullPortalReleased: !door.battlePortalFullExteriorResident,
                musicStillPlaying: false
            )
        } catch {
            print("[BattleRuntimeCleanup] cancellation cleanup failed error=\(error.localizedDescription)")
        }
        door.setBattleInteractionLocked(
            false,
            ownerID: instanceID,
            reason: "cancelCleanupFinished.\(reason)"
        )
        setEnemyMemoryPresence(false, reason: "cancelCleanupFinished.\(reason)")
        await releaseInteractionLease(
            reason: "battleCancelled.\(reason)"
        )
        resumeRuntimeReleaseWaiters()
        runtimeCleanupTask = nil
    }

    private func releaseUnregisteredPreparedEnemy(
        _ enemy: Battle01PreparedEnemy,
        lease: BattleEnemyRuntimeLease? = nil,
        reason: String
    ) async {
        onEnemyRemoved(enemy.enemyID)
        let releaseLease = lease ?? BattleEnemyRuntimeLease(
            identity: enemy.sourceController.battleRuntimeIdentity,
            controller: enemy.sourceController,
            portalMirror: enemy.portalMirror
        )
        do {
            _ = try await releaseLease.release(
                reason: .battleCancelled,
                retentionPolicy: .remove,
                corpsePresenter: corpsePresenter
            )
        } catch {
            print("[BattleRuntimeCleanup] unregistered enemy release failed reason=\(reason) error=\(error.localizedDescription)")
        }
    }

    private func setEnemyMemoryPresence(
        _ present: Bool,
        reason: String
    ) {
        guard enemyMemoryPresenceAnnounced != present else { return }
        enemyMemoryPresenceAnnounced = present
        onEnemyMemoryPresenceChanged(present, reason)
    }

    private func resumeRuntimeReleaseWaiters() {
        let waiters = runtimeReleaseWaiters.values
        runtimeReleaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        print("""
        [BattleRuntimeCleanup] Turing memory boundary ready
          remainingWaiterCount: 0
          fullPortalResident: \(door.battlePortalFullExteriorResident)
          activeEnemyRuntime: \(hasActiveBattleRuntime)
        """)
    }

    private func releaseInteractionLease(reason: String) async {
        guard let interactionLease else { return }
        self.interactionLease = nil
        await StoryInteractionArbiter.shared.release(
            interactionLease,
            reason: reason
        )
    }

    private func tryStartSoundtrackIfEligible(reason: String) {
        guard let instanceID = battleInstanceID else { return }
        let doorState = door.battleDoorState
        guard musicStartGate.claimIfEligible(
            doorState: doorState,
            mediaPrepared: soundtrackStartContext != nil
        ) else {
            return
        }
        guard let context = soundtrackStartContext else { return }

        Battle01EventLog.emit(
            "soundtrack trigger gate satisfied",
            instanceID: instanceID,
            state: state,
            fields: [
                ("scriptPoint03TTSCompleted", "true"),
                ("doorState", doorState.rawValue),
                ("reason", reason),
                ("requiresGrandmaAtA3", "false"),
                ("requiresPortalCrossing", "false")
            ]
        )

        do {
            try startSoundtrackAndScheduleRichPR(
                instanceID: instanceID,
                definition: context.definition,
                soundtrackURL: context.soundtrackURL,
                richDescriptor: context.richDescriptor,
                richURL: context.richURL
            )
        } catch {
            fail(error, instanceID: instanceID)
        }
    }

    private func startSoundtrackAndScheduleRichPR(
        instanceID: UUID,
        definition: Battle01Definition,
        soundtrackURL: URL,
        richDescriptor: TuringPrerecordingDescriptor,
        richURL: URL
    ) throws {
        try soundtrack.playOnce(
            battleInstanceID: instanceID,
            onStarted: { [weak self] returnedID in
                guard let self,
                      returnedID == instanceID,
                      self.battleInstanceID == instanceID else { return }
                self.soundtrackStarted = true
                Battle01EventLog.emit(
                    "soundtrack started",
                    instanceID: instanceID,
                    state: self.state,
                    fields: [
                        ("file", soundtrackURL.lastPathComponent),
                        ("loop", "false")
                    ]
                )
                self.scheduleRichPR(
                    instanceID: instanceID,
                    delay: definition.richPrerecording.delayAfterMusicPlaybackStartedSeconds,
                    descriptor: richDescriptor,
                    fileURL: richURL
                )
            },
            onCompleted: { [weak self] returnedID, success in
                guard let self,
                      returnedID == instanceID,
                      self.battleInstanceID == instanceID else { return }
                Battle01EventLog.emit(
                    "soundtrack completed",
                    instanceID: instanceID,
                    state: self.state,
                    fields: [("success", String(success))]
                )
            }
        )
    }

    private func scheduleRichPR(
        instanceID: UUID,
        delay: Double,
        descriptor: TuringPrerecordingDescriptor,
        fileURL: URL
    ) {
        richPRTask?.cancel()
        Battle01EventLog.emit(
            "Rich PR scheduled",
            instanceID: instanceID,
            state: state,
            fields: [("delaySeconds", String(format: "%.3f", delay))]
        )
        richPRTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: .seconds(delay))
                try Task.checkCancellation()
                guard self.battleInstanceID == instanceID else { return }
                try await self.richPR.play(
                    descriptor: descriptor,
                    fileURL: fileURL,
                    battleInstanceID: instanceID
                )
            } catch is CancellationError {
                return
            } catch {
                print("[Battle01] Rich PR failed error=\(error.localizedDescription)")
            }
        }
    }

    private func fail(_ error: Error, instanceID: UUID) {
        guard battleInstanceID == instanceID else { return }
        state = .failed
        Battle01EventLog.emit(
            "failed",
            instanceID: instanceID,
            state: state,
            fields: [("error", error.localizedDescription)]
        )
        cancel(reason: "failure.\(error.localizedDescription)")
    }
}
