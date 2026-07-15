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

    private let definitionStore = Battle01DefinitionStore()
    private let enemyFactory: Battle01EnemyFactory
    private let door: any TuringStoryDoorBattleControlling
    private let intro: ScriptedPortalEnemyIntroCoordinator
    private let combat: any Battle01StoryCombatControlling
    private let soundtrack: any Battle01SoundtrackControlling
    private let richPR: any Battle01RichPrerecordingPlaying
    private let prerecordingStore = TuringPrerecordingStore()
    private let clock: any BattleClock
    private let onEnemyRemoved: EnemyRemovedHook
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
    private var startTask: Task<Void, Never>?
    private var richPRTask: Task<Void, Never>?
    private var aftermathTransitionTask: Task<Void, Never>?
    private var prepared: Battle01PreparedEnemy?
    private var soundtrackStarted = false
    private var aftermathLoopStarted = false
    private var musicStartGate = Battle01MusicStartGate()
    private var soundtrackStartContext: SoundtrackStartContext?
    private var portalCrossingStarted = false
    private var latestPlayerTarget: SIMD3<Float>?

    init(
        sceneRoot: Entity,
        door: any TuringStoryDoorBattleControlling,
        clock: any BattleClock,
        onEnemyPrepared: @escaping EnemyPreparedHook,
        onEnemyRemoved: @escaping EnemyRemovedHook,
        playerTargetProvider: @escaping @MainActor () -> SIMD3<Float>?,
        onPlayerDamage: @escaping @MainActor (Float) -> Void
    ) {
        self.door = door
        self.clock = clock
        self.intro = ScriptedPortalEnemyIntroCoordinator(clock: clock)
        self.combat = Battle01StoryCombatAdapter()
        self.soundtrack = Battle01SoundtrackController()
        self.richPR = Battle01RichPrerecordingController()
        self.enemyFactory = Battle01EnemyFactory(
            sceneRoot: sceneRoot,
            onPrepared: onEnemyPrepared
        )
        self.onEnemyRemoved = onEnemyRemoved
        self.playerTargetProvider = playerTargetProvider
        self.onPlayerDamage = onPlayerDamage
    }

    func start(trigger: Battle01Trigger) {
        guard state == .unloaded,
              battleInstanceID == nil else {
            print("[Battle01] duplicate trigger ignored state=\(state.rawValue)")
            return
        }

        let instanceID = UUID()
        battleInstanceID = instanceID
        state = .preparing
        switch trigger {
        case .scriptPointCompleted(let event):
            guard event.scriptPointID == "prologue.scriptPoint03" else {
                battleInstanceID = nil
                state = .unloaded
                print("[Battle01] rejected non-ScriptPoint03 trigger scriptPointID=\(event.scriptPointID)")
                return
            }
            musicStartGate.recordScriptPoint03TTSCompletion()
        case .debug:
            musicStartGate.recordScriptPoint03TTSCompletion()
            print("[Battle01MusicGate] debug trigger simulates ScriptPoint03 TTS completion")
        }
        Battle01EventLog.emit(
            "triggered after ScriptPoint03",
            instanceID: instanceID,
            state: state
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
        startTask?.cancel()
        richPRTask?.cancel()
        aftermathTransitionTask?.cancel()
        soundtrack.stop(reason: reason)
        richPR.cancel(reason: reason)
        combat.cancel(reason: reason)
        intro.cancel(reason: reason)

        if let instanceID = battleInstanceID {
            door.setBattleInteractionLocked(
                false,
                ownerID: instanceID,
                reason: reason
            )
            if let enemyID = prepared?.enemyID {
                onEnemyRemoved(enemyID)
            }
            Battle01EventLog.emit(
                "cancelled",
                instanceID: instanceID,
                state: state,
                fields: [("reason", reason)]
            )
        }

        prepared = nil
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
            try Task.checkCancellation()
            guard battleInstanceID == instanceID else { return }
            prepared = enemy

            intro.install(
                prepared: enemy,
                doorContext: doorContext,
                definition: definition
            ) { [weak self] nextState in
                guard self?.battleInstanceID == instanceID else { return }
                self?.state = nextState
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

            door.setBattleInteractionLocked(
                false,
                ownerID: instanceID,
                reason: "portalExitComplete"
            )
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
                        self.state = .postBattleHold
                        Battle01EventLog.emit(
                            "corpse retained",
                            instanceID: instanceID,
                            state: self.state
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

                try self.soundtrack.crossfadeToAftermathLoop(
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
        soundtrack.stop(reason: "failure")
        richPR.cancel(reason: "failure")
        combat.cancel(reason: "failure")
        intro.cancel(reason: "failure")
        door.setBattleInteractionLocked(
            false,
            ownerID: instanceID,
            reason: "failure"
        )
        if let enemyID = prepared?.enemyID {
            onEnemyRemoved(enemyID)
        }
        Battle01EventLog.emit(
            "failed",
            instanceID: instanceID,
            state: state,
            fields: [("error", error.localizedDescription)]
        )
        prepared = nil
        startTask = nil
        richPRTask = nil
        aftermathTransitionTask?.cancel()
        aftermathTransitionTask = nil
        aftermathLoopStarted = false
        musicStartGate = Battle01MusicStartGate()
        soundtrackStartContext = nil
    }
}
