import Foundation
import QuartzCore
import RealityKit
import simd

@MainActor
final class Chapter01RobotEncounterCoordinator: Chapter01RobotEncounterControlling {
    private enum ComplianceResult {
        case stable
        case movement
    }

    private enum PortalMotionMode {
        case none
        case ingress
        case exit
    }

    private let definitionStore = Chapter01RobotDefinitionStore()
    private let door: TuringStoryDoorBundleController
    private let spatialProvider: PhaseOneSpatialProvider
    private let enemyRegistry: BattleEnemyRuntimeRegistry
    private let corpsePresenter: BattleCorpsePresentationController
    private let robotFactory: Chapter01RobotFactory
    private let speech = StoryRobotSpeechController()
    private let music = Chapter01MusicController.shared
    private let rewardTransaction: StoryRewardTransaction
    private let rewardPresenter: StoryItemRewardPresenter
    private let heavyRuntimeRegistry: StoryHeavyRuntimeRegistry
    private let progressStore: Chapter01ProgressStore
    private let pathFollower = ScriptedAnchorPathFollower()
    private let approachController = Chapter01RobotApproachController()
    private let approachTargetClamp: Chapter01RobotApproachController.TargetClamp
    private let onEnemyRemoved: @MainActor (UUID) -> Void
    private let onPlayerDamage: @MainActor (Int) -> Void
    private let onPlayerDeath: @MainActor () -> Void

    private(set) var state: Chapter01RobotEncounterState = .unloaded
    private var request: Chapter01RobotEncounterRequest?
    private var definition: Chapter01RobotDefinition?
    private var runtime: Chapter01RobotRuntime?
    private var activeTask: Task<Void, Never>?
    private var recoveryMonitorTask: Task<Void, Never>?
    private var pathContinuation: CheckedContinuation<Void, Error>?
    private var approachContinuation: CheckedContinuation<Void, Error>?
    private var playerHitBudget: StoryPlayerHitBudget?
    private var portalMotionMode: PortalMotionMode = .none
    private var warningPlayed = false
    private var movementDuringRecovery = false
    private var robotDeathHandled = false
    private var cleanupStarted = false
    private var generation: UInt64 = 0
    private var rewardSource: StoryRewardSource?
    private var robotAudioAttachment: (any Chapter01RobotAudioAttachment)?

    var hasActiveHeavyRuntime: Bool {
        runtime != nil || door.battlePortalFullExteriorResident
    }

    func validateAvailability() async throws {
        let availability = Chapter01RobotAvailability.evaluate()
        guard availability.isAvailable else {
            throw Chapter01RobotError.missingRewardArt(
                availability.missingAuthoredResources
            )
        }
        _ = try definitionStore.load()
        let rewardDescriptor = try Chapter01AntigenRewardDescriptor.load()
        try rewardPresenter.validateAuthoredReward(rewardDescriptor)
        try await speech.prepare(catalog: Chapter01RobotSpeechCatalog.load())
        try await music.prepare(catalog: Chapter01MusicCatalog.load())
    }

    init(
        sceneRoot: Entity,
        hudRoot: Entity,
        door: TuringStoryDoorBundleController,
        spatialProvider: PhaseOneSpatialProvider,
        inventory: StoryInventoryStore = .shared,
        heavyRuntimeRegistry: StoryHeavyRuntimeRegistry = .shared,
        progressStore: Chapter01ProgressStore = .shared,
        approachTargetClamp: @escaping Chapter01RobotApproachController.TargetClamp = { $0 },
        rewardAnchorResolver: @escaping StoryItemRewardPresenter.AnchorResolver,
        onEnemyPrepared: @escaping @MainActor (
            UUID,
            JockRetargetTestController
        ) -> (any Chapter01RobotAudioAttachment)? = { _, _ in nil },
        onEnemyRemoved: @escaping @MainActor (UUID) -> Void = { _ in },
        onPlayerDamage: @escaping @MainActor (Int) -> Void = { _ in },
        onPlayerDeath: @escaping @MainActor () -> Void = {}
    ) {
        let registry = BattleEnemyRuntimeRegistry()
        self.door = door
        self.spatialProvider = spatialProvider
        self.enemyRegistry = registry
        let corpsePresenter = BattleCorpsePresentationController(storyRoot: sceneRoot)
        self.corpsePresenter = corpsePresenter
        self.robotFactory = Chapter01RobotFactory(
            sceneRoot: sceneRoot,
            enemyRegistry: registry,
            corpsePresenter: corpsePresenter,
            onPrepared: onEnemyPrepared
        )
        self.rewardTransaction = StoryRewardTransaction(inventory: inventory)
        self.rewardPresenter = StoryItemRewardPresenter(
            hudRoot: hudRoot,
            anchorResolver: rewardAnchorResolver
        )
        self.heavyRuntimeRegistry = heavyRuntimeRegistry
        self.progressStore = progressStore
        self.approachTargetClamp = approachTargetClamp
        self.onEnemyRemoved = onEnemyRemoved
        self.onPlayerDamage = onPlayerDamage
        self.onPlayerDeath = onPlayerDeath
    }

    func start(request: Chapter01RobotEncounterRequest) async throws {
        guard self.request == nil,
              state == .unloaded || state == .released else {
            throw Chapter01RobotError.encounterAlreadyActive
        }
        guard request.battleLease.owner == .battle(
            battleInstanceID: request.chapterRunID
        ) else {
            throw StoryInteractionClaimError.staleLease
        }
        try await StoryInteractionArbiter.shared.requireCurrent(request.battleLease)

        try await validateAvailability()
        let definition = try definitionStore.load()
        _ = try await progressStore.commit(
            .robotEncounterPending,
            sourceEventID: request.chapterRunID
        )
        self.request = request
        self.definition = definition
        warningPlayed = false
        movementDuringRecovery = false
        robotDeathHandled = false
        cleanupStarted = false
        rewardSource = nil
        generation &+= 1
        let runGeneration = generation

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.run(
                    request: request,
                    definition: definition,
                    generation: runGeneration
                )
                // The encounter call stack owns temporary strong references to
                // the Robot during ingress, scan, combat, and departure. Only
                // test the final weak-release boundary after that stack has
                // returned and those locals are out of scope.
                await self.cleanup(
                    outcome: .rewardedRobotDeparted,
                    reason: "successfulRobotExit"
                )
            } catch is CancellationError {
                guard !self.robotDeathHandled else { return }
                await self.cleanup(outcome: .cancelled, reason: "encounterTaskCancelled")
            } catch {
                await self.fail(error, request: request)
            }
        }
    }

    func update(deltaTime: TimeInterval) {
        let combatTracksPlayer =
            state == .attackingNoncompliance || state == .stabilityRecovery
        let pose = spatialProvider.currentPose()

        runtime?.controller.update(
            deltaTime: Float(deltaTime),
            currentHeadPosition: combatTracksPlayer ? pose?.headPosition : nil
        )

        pathFollower.update(deltaTime: deltaTime)
        approachController.update(deltaTime: deltaTime)

        if let runtime {
            switch portalMotionMode {
            case .none:
                runtime.mirror.refreshPortalLightingIfNeeded()
            case .ingress:
                runtime.mirror.sync(
                    revealThreshold: -0.3048,
                    exitThreshold: 0.45
                )
            case .exit:
                runtime.mirror.syncRoomToPortal(
                    sourceHideThreshold: -0.05,
                    // The door, not an arbitrary portal-depth threshold, owns
                    // the final visible lifetime of a departing Robot.
                    exteriorReleaseThreshold: -Float.greatestFiniteMagnitude
                )
            }
        }

        if !combatTracksPlayer,
           shouldYawTrackPlayer,
           let controller = runtime?.controller,
           let pose {
            controller.setOrientationYawOnlyFacingPlayer(pose.headPosition)
        }
    }

    func cancel(reason: String) async {
        guard request != nil || hasActiveHeavyRuntime else { return }
        state = .cancelled
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        await cleanup(outcome: .cancelled, reason: reason)
    }

    func reset(reason: String) async {
        await cancel(reason: reason)
        state = .unloaded
    }

    private var shouldYawTrackPlayer: Bool {
        switch state {
        case .arrivedIdle, .scanInstructionPR, .initialCompliance,
             .complianceWarningPR, .complianceRestoredPR, .successfulScanPR:
            return true
        default:
            return false
        }
    }

    private func run(
        request: Chapter01RobotEncounterRequest,
        definition: Chapter01RobotDefinition,
        generation: UInt64
    ) async throws {
        try requireCurrent(request, generation: generation)
        transition(to: .preparingExterior)
        try await door.acquireBattlePortal(
            ownerID: request.chapterRunID,
            reason: "chapter01RobotAnimationPresent"
        )
        let doorContext = try door.chapter01RobotDoorContext()

        transition(to: .preparingRobot)
        let runtime = try await robotFactory.prepare(
            encounterID: request.chapterRunID,
            definition: definition,
            doorContext: doorContext
        )
        self.runtime = runtime
        robotAudioAttachment = runtime.externalAudioAttachment
        await heavyRuntimeRegistry.register(.robot(runtime.identity))
        await heavyRuntimeRegistry.register(
            .portalMirror(
                chapterRunID: request.chapterRunID,
                mirrorID: runtime.mirror.id
            )
        )

        let speechEndpoint = try Chapter01RobotAudioRoute.requireEndpoint()
        await speech.install(endpoint: speechEndpoint)
        try runtime.controller.playScriptedIdleLoop(
            clipID: definition.animations.idle
        )
        transition(to: .exteriorIdle)

        transition(to: .openingDoor)
        try await door.openForBattle(
            ownerID: request.chapterRunID,
            reason: "chapter01RobotIngress"
        )
        try requireCurrent(request, generation: generation)

        transition(to: .enteringPortal)
        portalMotionMode = .ingress
        let roomTarget = runtime.mirror.roomSideTarget(
            distance: 0.75,
            floorY: doorContext.robotDoorThreshold.position(relativeTo: nil).y
        )
        try await walk(
            controller: runtime.controller,
            clipID: definition.animations.walk,
            points: [
                ("robotDoorThreshold", doorContext.robotDoorThreshold.position(relativeTo: nil)),
                ("robotRoomEntry", roomTarget)
            ]
        )
        portalMotionMode = .none

        transition(to: .approachingPlayer)
        try await approach(
            runtime: runtime,
            definition: definition
        )
        try runtime.controller.playScriptedIdleLoop(
            clipID: definition.animations.idle
        )
        transition(to: .arrivedIdle)

        transition(to: .scanInstructionPR)
        try await speech.play(.scanInstruction, encounterID: request.chapterRunID)
        try await runInitialCompliance(
            request: request,
            definition: definition,
            generation: generation
        )
    }

    private func runInitialCompliance(
        request: Chapter01RobotEncounterRequest,
        definition: Chapter01RobotDefinition,
        generation: UInt64
    ) async throws {
        transition(to: .initialCompliance)
        switch try await awaitCompliance(
            definition: definition,
            stopOnFirstMovement: true,
            generation: generation
        ) {
        case .stable:
            try await completeSuccessfulScan(
                request: request,
                definition: definition,
                generation: generation
            )
        case .movement:
            try await issueWarningAndAttack(
                request: request,
                definition: definition,
                generation: generation
            )
        }
    }

    private func issueWarningAndAttack(
        request: Chapter01RobotEncounterRequest,
        definition: Chapter01RobotDefinition,
        generation: UInt64
    ) async throws {
        if !warningPlayed {
            warningPlayed = true
            transition(to: .complianceWarningPR)
            try await speech.play(.complianceWarning, encounterID: request.chapterRunID)
        }
        try await beginAttackAndRecovery(
            request: request,
            definition: definition,
            generation: generation
        )
    }

    private func beginAttackAndRecovery(
        request: Chapter01RobotEncounterRequest,
        definition: Chapter01RobotDefinition,
        generation: UInt64
    ) async throws {
        guard let controller = runtime?.controller else {
            throw Chapter01RobotError.invalidEncounterState("missing Robot during combat")
        }
        transition(to: .attackingNoncompliance)
        try await music.play(.robotAttack, chapterRunID: request.chapterRunID)
        playerHitBudget = StoryPlayerHitBudget(
            maximumConfirmedHits: definition.combat.confirmedRobotHitsToKillPlayer
        )
        controller.onBenchmarkPlayerHit = { [weak self] amount, _ in
            guard let self, let budget = self.playerHitBudget else { return false }
            let terminal = budget.registerConfirmedHit()
            if terminal {
                self.onPlayerDamage(amount)
                Task { @MainActor [weak self] in
                    await self?.handlePlayerDeath(request: request)
                }
            }
            return terminal
        }
        controller.setStoryPlayerHitCallbackOwnsBudget(true)
        controller.onPlayerDamaged = { [weak self] amount in
            self?.onPlayerDamage(amount)
        }
        controller.onBenchmarkEnemyKilled = { [weak self] _, _ in
            self?.transition(to: .robotDeathAnimation)
        }
        controller.onBenchmarkEnemyDeathAnimationFinished = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                await self.handleRobotDeath(
                    request: request,
                    generation: generation
                )
            }
        }
        try controller.activateStoryCombat()
        transition(to: .stabilityRecovery)
        _ = try await awaitCompliance(
            definition: definition,
            stopOnFirstMovement: false,
            generation: generation
        )
        try requireCurrent(request, generation: generation)
        await music.stop(
            .robotAttack,
            chapterRunID: request.chapterRunID,
            reason: "complianceRestored"
        )
        controller.setCombatEnabled(false)
        playerHitBudget?.disable()
        try controller.playScriptedIdleLoop(
            clipID: definition.animations.idle
        )
        print(
            "[Chapter01RobotScan] diagnostic idle restored " +
                "clipID=\(definition.animations.idle)"
        )

        movementDuringRecovery = false
        recoveryMonitorTask = makeRecoveryMonitor(
            definition: definition,
            generation: generation
        )
        transition(to: .complianceRestoredPR)
        try await speech.play(.complianceRestored, encounterID: request.chapterRunID)
        recoveryMonitorTask?.cancel()
        recoveryMonitorTask = nil

        if movementDuringRecovery {
            try await beginAttackAndRecovery(
                request: request,
                definition: definition,
                generation: generation
            )
        } else {
            try await completeSuccessfulScan(
                request: request,
                definition: definition,
                generation: generation
            )
        }
    }

    private func completeSuccessfulScan(
        request: Chapter01RobotEncounterRequest,
        definition: Chapter01RobotDefinition,
        generation: UInt64
    ) async throws {
        guard let controller = runtime?.controller else { return }
        controller.setCombatEnabled(false)
        playerHitBudget?.disable()
        transition(to: .successfulScanPR)
        try await speech.play(.successfulScan, encounterID: request.chapterRunID)
        try await grantAntigen(
            source: .scanSuccess,
            request: request,
            definition: definition
        )
        transition(to: .exitConfirmationPR)
        try await speech.play(.exitConfirmation, encounterID: request.chapterRunID)
        try requireCurrent(request, generation: generation)
        try await runSuccessfulExit(
            request: request,
            definition: definition,
            generation: generation
        )
    }

    private func runSuccessfulExit(
        request: Chapter01RobotEncounterRequest,
        definition: Chapter01RobotDefinition,
        generation: UInt64
    ) async throws {
        try await performSuccessfulExit(
            request: request,
            definition: definition,
            generation: generation
        )
    }

    private func performSuccessfulExit(
        request: Chapter01RobotEncounterRequest,
        definition: Chapter01RobotDefinition,
        generation: UInt64
    ) async throws {
        guard let runtime else { return }
        let context = try door.chapter01RobotDoorContext()
        let current = runtime.controller.rootEntity.position(relativeTo: nil)
        let exteriorMid = context.robotExteriorMid.position(relativeTo: nil)
        let exteriorStart = context.robotExteriorStart.position(relativeTo: nil)
        transition(to: .walkingToDoor)
        try runtime.mirror.prepareForRoomToPortalExit()
        await heavyRuntimeRegistry.register(
            .portalMirror(
                chapterRunID: request.chapterRunID,
                mirrorID: runtime.mirror.id
            )
        )
        portalMotionMode = .exit
        transition(to: .exitingPortal)
        try await walk(
            controller: runtime.controller,
            clipID: definition.animations.walk,
            points: [
                ("robotRoomExitStart", current),
                ("robotDoorThreshold", context.robotDoorThreshold.position(relativeTo: nil)),
                ("robotExteriorMid", exteriorMid),
                ("robotExteriorStart", exteriorStart)
            ]
        )
        try requireCurrent(request, generation: generation)

        let departureDirection = PhaseOneMath.normalizedOrFallback(
            exteriorStart - exteriorMid,
            fallback: SIMD3<Float>(0, 0, -1)
        )
        let departureTarget = exteriorStart + departureDirection * 8
        let continuedWalk = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.walk(
                controller: runtime.controller,
                clipID: definition.animations.walk,
                points: [
                    ("robotExteriorStart", exteriorStart),
                    ("robotExteriorContinuation", departureTarget)
                ]
            )
        }
        await Task.yield()

        do {
            try await door.closeForBattleAndUnloadPortal(
                ownerID: request.chapterRunID,
                reason: "successfulRobotDeparture"
            )
        } catch {
            pathFollower.cancel(reason: "robotDepartureDoorCloseFailed")
            finishPath(.failure(error))
            _ = try? await continuedWalk.value
            throw error
        }

        guard door.battleDoorState == .closed,
              !door.battlePortalFullExteriorResident else {
            throw Chapter01RobotError.portalReleaseBoundaryFailed
        }

        // Closing the door is the visual cutoff. Stop the now-occluded walk
        // and release the mirror/runtime only after close and unload complete.
        pathFollower.cancel(reason: "robotDepartureDoorClosed")
        finishPath(.success(()))
        _ = try? await continuedWalk.value
        await robotAudioAttachment?.deactivate(
            reason: "doorClosedAndExteriorUnloaded"
        )
        try requireCurrent(request, generation: generation)
        portalMotionMode = .none
        print(
            """
            [Chapter01RobotExit] departure completed behind closed door
              departureDirection: \(departureDirection)
              departureTarget: \(departureTarget)
              doorClosedBeforeRuntimeRelease: \(door.battleDoorState == .closed)
              exteriorUnloadedBeforeRuntimeRelease: \(!door.battlePortalFullExteriorResident)
            """
        )
    }

    private func handleRobotDeath(
        request: Chapter01RobotEncounterRequest,
        generation: UInt64
    ) async {
        guard !robotDeathHandled, self.request?.chapterRunID == request.chapterRunID else { return }
        robotDeathHandled = true
        activeTask?.cancel()
        activeTask = nil
        recoveryMonitorTask?.cancel()
        runtime?.controller.setCombatEnabled(false)
        playerHitBudget?.disable()

        await music.stop(
            .robotAttack,
            chapterRunID: request.chapterRunID,
            reason: "robotDeathAnimationCompleted"
        )
        transition(to: .payloadReleasePR)
        do {
            guard let definition else { throw Chapter01RobotError.invalidEncounterState("missing definition") }
            try await speech.play(.payloadRelease, encounterID: request.chapterRunID)
            try await grantAntigen(
                source: .robotKilled,
                request: request,
                definition: definition
            )
            guard generation == self.generation else { return }
            await cleanup(outcome: .rewardedRobotDestroyed, reason: "robotDestroyed")
        } catch {
            await fail(error, request: request)
        }
    }

    private func handlePlayerDeath(request: Chapter01RobotEncounterRequest) async {
        guard self.request?.chapterRunID == request.chapterRunID,
              state != .playerDead else { return }
        transition(to: .playerDead)
        runtime?.controller.setCombatEnabled(false)
        onPlayerDeath()
        await cleanup(outcome: .playerDeadBeforeReward, reason: "fiveConfirmedRobotContacts")
    }

    private func grantAntigen(
        source: StoryRewardSource,
        request: Chapter01RobotEncounterRequest,
        definition: Chapter01RobotDefinition
    ) async throws {
        transition(to: .rewarding(source: source))
        let descriptor = try Chapter01AntigenRewardDescriptor.load()
        let result = try await rewardTransaction.grant(
            StoryRewardRequest(
                eventID: definition.reward.eventID,
                itemID: definition.reward.itemID,
                quantity: definition.reward.quantity,
                source: source,
                sourceRuntimeID: request.chapterRunID
            )
        )
        _ = try await progressStore.commit(
            .antigenGranted,
            sourceEventID: UUID()
        )
        try await rewardPresenter.reconcileWorldPresentation(
            itemID: definition.reward.itemID,
            inventoryQuantity: result.totalQuantity,
            descriptor: descriptor
        )
        // Inventory remains exactly-once, but every completed encounter must
        // visibly acknowledge the payload, including replay in development.
        try await rewardPresenter.presentHUDReward(
            itemID: definition.reward.itemID,
            text: definition.reward.hudText,
            descriptor: descriptor
        )
        rewardSource = source
    }

    private func awaitCompliance(
        definition: Chapter01RobotDefinition,
        stopOnFirstMovement: Bool,
        generation: UInt64
    ) async throws -> ComplianceResult {
        let detector = HeadStillnessDetector(
            configuration: HeadStillnessDetector.Configuration(
                requiredStableSeconds: definition.scan.stableDurationSeconds,
                translationToleranceMeters: definition.scan.translationToleranceMeters,
                rotationToleranceRadians: definition.scan.rotationToleranceDegrees * .pi / 180,
                trackingLossGraceSeconds: definition.scan.trackingLossGraceSeconds
            )
        )
        let interval = UInt64((1_000_000_000 / definition.scan.sampleRateHz).rounded())
        while !Task.isCancelled {
            guard generation == self.generation else { throw CancellationError() }
            let transform = spatialProvider.currentTrackedDeviceTransform()
            let event = await detector.ingest(
                HeadStillnessDetector.Sample(
                    timestampSeconds: CACurrentMediaTime(),
                    transform: transform,
                    isTracked: transform != nil
                )
            )
            switch event {
            case .movement where stopOnFirstMovement:
                return .movement
            case .completed:
                return .stable
            case .progress(let seconds, let fraction):
                print("[Chapter01RobotScan] progress seconds=\(seconds) fraction=\(fraction)")
            default:
                break
            }
            try await Task.sleep(nanoseconds: interval)
        }
        throw CancellationError()
    }

    private func makeRecoveryMonitor(
        definition: Chapter01RobotDefinition,
        generation: UInt64
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let detector = HeadStillnessDetector(
                configuration: HeadStillnessDetector.Configuration(
                    requiredStableSeconds: definition.scan.stableDurationSeconds,
                    translationToleranceMeters: definition.scan.translationToleranceMeters,
                    rotationToleranceRadians: definition.scan.rotationToleranceDegrees * .pi / 180,
                    trackingLossGraceSeconds: definition.scan.trackingLossGraceSeconds
                )
            )
            let interval = UInt64((1_000_000_000 / definition.scan.sampleRateHz).rounded())
            while !Task.isCancelled, generation == self.generation {
                let transform = self.spatialProvider.currentTrackedDeviceTransform()
                let event = await detector.ingest(
                    HeadStillnessDetector.Sample(
                        timestampSeconds: CACurrentMediaTime(),
                        transform: transform,
                        isTracked: transform != nil
                    )
                )
                if event == .movement {
                    self.movementDuringRecovery = true
                }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func walk(
        controller: JockRetargetTestController,
        clipID: String,
        points: [(String, SIMD3<Float>)]
    ) async throws {
        guard points.count >= 2 else { return }
        let segments = zip(points, points.dropFirst()).map { from, to in
            ScriptedAnchorPathFollower.Segment(
                fromID: from.0,
                toID: to.0,
                fromWorld: from.1,
                toWorld: to.1
            )
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pathContinuation = continuation
                do {
                    try pathFollower.begin(
                        controller: controller,
                        segments: segments,
                        walkClipID: clipID
                    ) { [weak self] in
                        self?.finishPath(.success(()))
                    }
                } catch {
                    finishPath(.failure(error))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.pathFollower.cancel(reason: "chapter01RobotPathCancelled")
                self?.finishPath(.failure(CancellationError()))
            }
        }
    }

    private func approach(
        runtime: Chapter01RobotRuntime,
        definition: Chapter01RobotDefinition
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                approachContinuation = continuation
                do {
                    try approachController.begin(
                        controller: runtime.controller,
                        spatialProvider: spatialProvider,
                        walkClipID: definition.animations.walk,
                        configuration: definition.approach,
                        targetClamp: approachTargetClamp
                    ) { [weak self] in
                        self?.finishApproach(.success(()))
                    }
                } catch {
                    finishApproach(.failure(error))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.approachController.cancel(reason: "chapter01RobotApproachCancelled")
                self?.finishApproach(.failure(CancellationError()))
            }
        }
    }

    private func finishPath(_ result: Result<Void, Error>) {
        let continuation = pathContinuation
        pathContinuation = nil
        switch result {
        case .success: continuation?.resume()
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }

    private func finishApproach(_ result: Result<Void, Error>) {
        let continuation = approachContinuation
        approachContinuation = nil
        switch result {
        case .success: continuation?.resume()
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }

    private func cleanup(
        outcome: Chapter01RobotCleanupOutcome,
        reason: String
    ) async {
        guard !cleanupStarted else { return }
        cleanupStarted = true
        transition(to: .releasing)
        generation &+= 1
        recoveryMonitorTask?.cancel()
        recoveryMonitorTask = nil
        pathFollower.cancel(reason: reason)
        approachController.cancel(reason: reason)
        finishPath(.failure(CancellationError()))
        finishApproach(.failure(CancellationError()))
        portalMotionMode = .none

        if let request {
            await speech.stop(encounterID: request.chapterRunID, reason: reason)
            await music.stopAll(chapterRunID: request.chapterRunID, reason: reason)
        }
        runtime?.controller.setCombatEnabled(false)
        playerHitBudget?.disable()
        await robotAudioAttachment?.deactivate(
            reason: "cleanupFallback.\(reason)"
        )

        let runtimeIdentity = runtime?.identity
        let enemyID = runtimeIdentity?.enemyID
        runtime = nil
        var weakReleased = true
        var allHeavyReleasesCompleted = true
        if let request {
            let leases = enemyRegistry.drain(battleInstanceID: request.chapterRunID)
            for lease in leases {
                do {
                    let result = try await lease.release(
                        reason: outcome.battleReleaseReason,
                        retentionPolicy: .remove,
                        corpsePresenter: corpsePresenter
                    )
                    weakReleased = weakReleased && result.weakControllerReleased
                    allHeavyReleasesCompleted =
                        allHeavyReleasesCompleted && result.heavyRuntimeReleased
                } catch {
                    weakReleased = false
                    allHeavyReleasesCompleted = false
                    print("[Chapter01RobotCleanup] enemy release failed error=\(error.localizedDescription)")
                }
            }
            if allHeavyReleasesCompleted {
                await heavyRuntimeRegistry.removeRobotOwnedRuntimes(
                    chapterRunID: request.chapterRunID
                )
            }
        }
        if let enemyID { onEnemyRemoved(enemyID) }

        Chapter01RobotAudioRoute.clear(reason: reason)
        await speech.reset(reason: reason)
        if let request, door.battlePortalFullExteriorResident {
            do {
                try await door.closeForBattleAndUnloadPortal(
                    ownerID: request.chapterRunID,
                    reason: reason
                )
            } catch {
                print("[Chapter01RobotCleanup] door close/unload failed error=\(error.localizedDescription)")
            }
        }

        guard let request else {
            state = .released
            return
        }
        let snapshot = await StoryInteractionArbiter.shared.currentSnapshot()
        let memory = BattleRuntimeMemorySnapshot.capture(
            label: "afterChapter01RobotRuntimeReleased"
        )
        let heavy = await heavyRuntimeRegistry.snapshot(chapterRunID: request.chapterRunID)
        activeTask = nil
        let report = Chapter01RobotReleaseReport(
            chapterRunID: request.chapterRunID,
            outcome: outcome,
            dadRuntimeCount: heavy.filter {
                if case .dad = $0 { return true }
                return false
            }.count,
            robotRuntimeCount: heavy.filter {
                if case .robot = $0 { return true }
                return false
            }.count,
            preparedClipCount: weakReleased ? 0 : 1,
            portalMirrorCount: heavy.filter {
                if case .portalMirror = $0 { return true }
                return false
            }.count,
            fullExteriorResident: door.battlePortalFullExteriorResident,
            doorState: snapshot.doorState,
            robotSpeechHandleCount: await speech.activeHandleCount(),
            robotCombatHandleCount: 0,
            activeEncounterTaskCount: 0,
            weakRobotControllerReleased: weakReleased,
            robotPresenceAudioActive: robotAudioAttachment?.isActive ?? false,
            robotExternalAudioSourceCount: robotAudioAttachment?.isActive == true ? 1 : 0,
            physicalFootprintMB: memory.physicalFootprintMB,
            residentSizeMB: memory.residentSizeMB
        )
        print(
            """
            [Chapter01RobotCleanup] release boundary
              outcome: \(outcome)
              doorState: \(report.doorState)
              fullExteriorResident: \(report.fullExteriorResident)
              robotPresenceAudioActive: \(report.robotPresenceAudioActive)
              robotExternalAudioSourceCount: \(report.robotExternalAudioSourceCount)
              robotRuntimeCount: \(report.robotRuntimeCount)
              portalMirrorCount: \(report.portalMirrorCount)
              preparedClipCount: \(report.preparedClipCount)
              safeForPostRobotHub: \(report.isSafeForPostRobotHub)
              physicalFootprintMB: \(report.physicalFootprintMB)
              residentSizeMB: \(report.residentSizeMB)
            """
        )

        let completionSink = request.completionSink
        let finalRewardSource = rewardSource
        self.request = nil
        self.definition = nil
        self.robotAudioAttachment = nil
        state = .released

        switch outcome {
        case .rewardedRobotDeparted, .rewardedRobotDestroyed:
            guard report.isSafeForPostRobotHub, let finalRewardSource else {
                await completionSink.robotEncounterFailed(
                    Chapter01RobotEncounterFailureEvent(
                        chapterRunID: request.chapterRunID,
                        message: "Robot heavy-runtime release boundary did not pass.",
                        retryCheckpointID: "chapter01.robotEncounter.pending"
                    )
                )
                return
            }
            var transitionLease: StoryInteractionLease?
            do {
                let transferred = try await StoryInteractionArbiter.shared.transferBattleToStoryTransition(
                    battleLease: request.battleLease,
                    transitionID: UUID(),
                    reason: "chapter01RobotRuntimeReleased"
                )
                transitionLease = transferred
                try await completionSink.robotEncounterCompleted(
                    Chapter01RobotEncounterCompletionEvent(
                        chapterRunID: request.chapterRunID,
                        rewardSource: finalRewardSource,
                        releaseReport: report,
                        postRobotTransitionLease: transferred
                    )
                )
            } catch {
                if let transitionLease {
                    await StoryInteractionArbiter.shared.release(
                        transitionLease,
                        reason: "chapter01PostRobotHandoffFailed"
                    )
                } else {
                    await StoryInteractionArbiter.shared.release(
                        request.battleLease,
                        reason: "chapter01HamTransferFailed"
                    )
                }
                await completionSink.robotEncounterFailed(
                    Chapter01RobotEncounterFailureEvent(
                        chapterRunID: request.chapterRunID,
                        message: error.localizedDescription,
                        retryCheckpointID: "chapter01.postRobotHub"
                    )
                )
            }
        case .playerDeadBeforeReward, .retryableFailure:
            await StoryInteractionArbiter.shared.release(
                request.battleLease,
                reason: reason
            )
            await completionSink.robotEncounterFailed(
                Chapter01RobotEncounterFailureEvent(
                    chapterRunID: request.chapterRunID,
                    message: reason,
                    retryCheckpointID: "chapter01.robotEncounter.pending"
                )
            )
        case .cancelled, .storyTeardown, .immersiveTeardown:
            await StoryInteractionArbiter.shared.release(
                request.battleLease,
                reason: reason
            )
        }
    }

    private func fail(
        _ error: Error,
        request: Chapter01RobotEncounterRequest
    ) async {
        state = .failed(message: error.localizedDescription)
        await cleanup(outcome: .retryableFailure, reason: error.localizedDescription)
    }

    private func requireCurrent(
        _ request: Chapter01RobotEncounterRequest,
        generation: UInt64
    ) throws {
        guard self.request?.chapterRunID == request.chapterRunID,
              self.generation == generation,
              !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func transition(to next: Chapter01RobotEncounterState) {
        print("[Chapter01Robot] state \(state) -> \(next)")
        state = next
    }
}
