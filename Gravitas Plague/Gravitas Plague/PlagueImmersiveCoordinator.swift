import Foundation
import Combine
import QuartzCore
import RealityKit
import simd
import UIKit

@MainActor
final class PlagueImmersiveCoordinator: ObservableObject {
    private struct HordeSpawnFailureRecord: Identifiable {
        let id = UUID()
        let wave: Int
        let spawnIndex: Int
        let archetype: PlagueCharacterArchetype
        let reason: String
    }

    private struct HordeCorpseRecord {
        let enemyID: UUID
        let characterID: String
        let rootEntity: Entity
        let controller: JockRetargetTestController
        let deathTime: TimeInterval
    }

    private enum HordeWaveSpawnState: String {
        case idle
        case spawning
        case active
        case degraded
        case failed
    }

    private enum HordeRuntimePhase: String {
        case idle
        case waitingForRoomScan
        case creatingFirstPortal
        case portalsReady
        case spawningWave
        case activeWave
        case playerDead
    }

    private let spatialProvider = PhaseOneSpatialProvider()
    private let audioController = GravitasDemoAudioController()
    private let forestEnvironmentController = PlagueGaussianForestEnvironmentController()
    private let roomSkinningCoordinator = RoomSkinningCoordinator()
    private let hordePortalManager = HordePortalManager()
    private let wallPosterUIController = WallMountedPosterUIController()
    private let wallPropOccupancyRegistry = WallPropOccupancyRegistry()
    private let hordeRoomScanTracker = HordeRoomScanTracker()
    private let enemyBodySeparationResolver = HordeEnemyBodySeparationResolver()
    private let instructionHUD = PlagueHeadTrackedInstructionHUD()
    private let timingProfiler = TimingProfiler(label: "main_actor_shell")
    private let hordeSimulationEngine = HordeSimulationEngine()
    private let hordeEnemyBrainEngine = HordeEnemyBrainEngine()
    private let hordePrewarmCoordinator = HordePrewarmCoordinator()

    private var architectureFrameIndex = 0
    private var latestFrameClockSnapshot: FrameClockSnapshot?
    private var latestPlayerPoseSnapshot: PlayerPoseSnapshot?
    private var latestEnemyBodySnapshots: [EnemyBodySnapshot] = []
    private var latestEnemyBrainSnapshots: [EnemyBrainSnapshot] = []
    private var latestPortalRuntimeSnapshots: [PortalRuntimeSnapshot] = []
    private var pendingHordeSimulationCommands: HordeSimulationCommands?
    private var hordeSimulationInFlight = false
    private var hordeSimulationTask: Task<Void, Never>?
    private var pendingHordeBrainCommands: HordeEnemyBrainCommands?
    private var hordeBrainInFlight = false
    private var hordeBrainTask: Task<Void, Never>?

    @Published private(set) var isPlayerDeathSequenceActive = false

    var onPlayerDamaged: ((Int) -> Void)?
    var onPlayerDeathStarted: (() -> Void)?
    var onForestAtmosphereFatalFailure: ((Error) -> Void)? {
        didSet {
            forestEnvironmentController.onStrictAtmosphereFailure = onForestAtmosphereFatalFailure
        }
    }
    var onForestSplatLoadStatusChanged: ((String) -> Void)? {
        didSet {
            forestEnvironmentController.onSplatLoadStatusChanged = onForestSplatLoadStatusChanged
        }
    }
    var onForestGeometryLoadStatusChanged: ((String) -> Void)? {
        didSet {
            forestEnvironmentController.onGeometryLoadStatusChanged = onForestGeometryLoadStatusChanged
        }
    }
    var onForestAppearanceStatusChanged: ((String) -> Void)? {
        didSet {
            forestEnvironmentController.onAppearanceStatusChanged = onForestAppearanceStatusChanged
        }
    }
    var onWallPosterUIActiveChanged: ((Bool) -> Void)?
    var onHordeWaveReached: ((Int) -> Void)?
    var onHordeWaveCleared: ((Int) -> Void)?
    var onHordeSessionEnded: (() -> Void)?
    var onRoomSkinningStatusChanged: ((String) -> Void)? {
        didSet {
            roomSkinningCoordinator.onStatusChanged = onRoomSkinningStatusChanged
        }
    }
    weak var deathPresentationController: DeathPresentationController?

    private var sceneRoot: AnchorEntity?
    private var headAnchor: AnchorEntity?
    private var youDiedRunning = false
    private var youDiedRig: Entity?
    private var youDiedLogo: ModelEntity?
    private var youDiedAlpha: Float = 0.0

    private var jockRetargetController: JockRetargetTestController?
    private var hordeEnemyControllersByID: [UUID: JockRetargetTestController] = [:]
    private var hordeDyingEnemyControllersByID: [UUID: JockRetargetTestController] = [:]
    private var hordeCorpseRecordsByID: [UUID: HordeCorpseRecord] = [:]
    private var activeHordeEnemyIDs = Set<UUID>()
    private var dyingHordeEnemyIDs = Set<UUID>()
    private var corpseHordeEnemyIDs = Set<UUID>()
    private var hordeBenchmarkRunning = false
    private var hordeRuntimePhase: HordeRuntimePhase = .idle
    private var hordeCurrentWave = 0
    private var hordePlayerHitsThisWave = 0
    private var hordeTotalSpawned = 0
    private var hordeTotalKilled = 0
    private var nextGlobalEnemySpawnIndex = 0
    private var hordeWaveSpawnState: HordeWaveSpawnState = .idle
    private var hordeSpawnFailures: [HordeSpawnFailureRecord] = []
    private var isSpawningHordeWave = false
    private var hordePrewarmReady = false
    private var hordePrewarmTask: Task<Bool, Never>?
    private var hordeScoresSubmittedForCurrentRun = false
    private var hordeWaitingForRoomScan = false
    private var hordeWaitingForFloorPromptShown = false
    private var hordeRoomScanCompletionTask: Task<Void, Never>?
    private var activeIngressControllers: [UUID: HordePortalInstancedIngressController] = [:]
    private var lastWallPosterPlacementAttempt: Date?

    private var lastTickDate: Date?
    private var handledCommandIDs = Set<UUID>()
    private var pendingCommands: [PlagueDemoSession.CommandEnvelope] = []
    private var pendingNextBenchmarkWaveTask: Task<Void, Never>?

    private var hordePortalSystemReady: Bool {
        !hordePortalManager.portals.isEmpty &&
            (
                hordeRuntimePhase == .portalsReady ||
                hordeRuntimePhase == .spawningWave ||
                hordeRuntimePhase == .activeWave
            )
    }

    private let benchmarkNextWaveDelaySeconds: TimeInterval = 1.20
    private let hordePlayerHitLimitPerWave = 3
    private let hordeSpawnRadiusMeters: Float = 2.45
    private let YOU_DIED_FORWARD_M: Float = 1.25
    private let YOU_DIED_Y_OFFSET_M: Float = 7.0 * 0.3048
    private let YOU_DIED_WIDTH_M: Float = 1.70
    private let YOU_DIED_HEIGHT_M: Float = 0.84

    func makeSceneRoot(
        initialAtmosphere: PlagueForestAtmosphere,
        atmosphereRevision: Int
    ) async -> AnchorEntity {
        if let sceneRoot {
            return sceneRoot
        }

        let root = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
        root.name = "GravitasPlague_PhaseOne_SceneRoot"
        PlagueNativeBloomInstaller.installStrictBloom(
            on: root
        )

        do {
            try CharacterAttributeStore.shared.loadStrict()
        } catch {
            print(
                """
                [CharacterAttributes] ERROR strict startup validation failed
                  error: \(error.localizedDescription)
                  noFallback: true
                """
            )
        }

        PortalHDRIAssetValidator.validate()
        HordePortalAssetValidator.validate()

        let head = makeHeadAnchor()
        instructionHUD.ensure(on: head)

        roomSkinningCoordinator.installIfNeeded(sceneRoot: root)
        hordePortalManager.install(
            sceneRoot: root,
            audioController: audioController,
            wallManager: roomSkinningCoordinator.wallManager,
            occupancyRegistry: wallPropOccupancyRegistry
        )
        wallPosterUIController.installIfNeeded(
            sceneRoot: root,
            wallManager: roomSkinningCoordinator.wallManager,
            hordePortalManager: hordePortalManager,
            occupancyRegistry: wallPropOccupancyRegistry
        )
        forestEnvironmentController.applyIBLReceiverRecursively(
            root: wallPosterUIController.root
        )
        roomSkinningCoordinator.startHordeRoomScanOnly()

        spatialProvider.onPlaneAnchorUpdate = { [weak self] update in
            self?.roomSkinningCoordinator.handlePlaneAnchorUpdate(update)
        }

        await spatialProvider.start()

        self.sceneRoot = root
        validateDeathPresentationAssets()

        drainPendingCommands()

        return root
    }

    func updateForestAtmosphereIfNeeded(
        atmosphere: PlagueForestAtmosphere,
        revision: Int
    ) async {
        // Gaussian forest loading is intentionally dormant for the room-skinning MVP.
    }

    func makeHeadAnchor() -> AnchorEntity {
        if let headAnchor {
            return headAnchor
        }

        let head = AnchorEntity(.head)
        head.name = "GravitasPlague_HeadAnchor"
        headAnchor = head

        return head
    }

    private func ensureJockRetargetController() -> JockRetargetTestController? {
        if let jockRetargetController {
            return jockRetargetController
        }

        guard let sceneRoot else {
            return nil
        }

        let controller = JockRetargetTestController()
        wireJockCallbacks(controller)
        sceneRoot.addChild(controller.rootEntity)

        audioController.attachToSceneIfNeeded(
            sceneRoot: sceneRoot,
            hostRootEntity: controller.rootEntity
        )

        jockRetargetController = controller

        print(
            """
            [Gravitas] JockAsset controller created lazily
              reason: non_horde_character_mode
            """
        )

        return controller
    }

    var isDoorHandleDragActive: Bool {
        roomSkinningCoordinator.isDoorHandleDragActive
    }

    func beginDoorHandleDrag(
        worldPoint: SIMD3<Float>
    ) {
        roomSkinningCoordinator.beginDoorHandleDrag(
            worldPoint: worldPoint
        )
    }

    func updateDoorHandleDrag(
        worldPoint: SIMD3<Float>
    ) {
        roomSkinningCoordinator.updateDoorHandleDrag(
            worldPoint: worldPoint
        )
    }

    func endDoorHandleDrag(
        shouldConfirm: Bool = true
    ) {
        roomSkinningCoordinator.endDoorHandleDrag(
            shouldConfirm: shouldConfirm
        )
    }

    private func wireJockCallbacks(
        _ jockController: JockRetargetTestController,
        hostAudioSourceID: UUID? = nil
    ) {
        jockController.onPunchHit = { [weak self, weak jockController] hitRegion in
            Task { @MainActor in
                guard let jockController else {
                    return
                }

                self?.audioController.playConfirmedCharacterFaceHitSound(
                    archetype: jockController.archetype,
                    enemyID: jockController.hordeBenchmarkID,
                    hitRegion: hitRegion,
                    sourceID: hostAudioSourceID
                )
            }
        }

        jockController.onCharacterDamageHit = { [weak self, weak jockController] in
            Task { @MainActor in
                guard let jockController,
                      let hostAudioSourceID else {
                    return
                }

                self?.audioController.playCharacterDamageHit(
                    archetype: jockController.archetype,
                    enemyID: jockController.hordeBenchmarkID,
                    sourceID: hostAudioSourceID
                )
            }
        }

        jockController.onCharacterDeath = { [weak self, weak jockController] in
            Task { @MainActor in
                guard let jockController,
                      let hostAudioSourceID else {
                    return
                }

                self?.audioController.playCharacterDeath(
                    archetype: jockController.archetype,
                    enemyID: jockController.hordeBenchmarkID,
                    sourceID: hostAudioSourceID
                )
            }
        }

        jockController.onPlayerDamaged = { [weak self] amount in
            Task { @MainActor in
                self?.audioController.playRandomPlayerDamageHit()
                self?.onPlayerDamaged?(amount)
            }
        }

        jockController.onBenchmarkPlayerHit = { [weak self] amount, attackerID in
            guard let self else { return false }

            return self.registerConfirmedHordePlayerHit(
                amount: amount,
                attackerID: attackerID
            )
        }

        jockController.onBenchmarkPlayerDeath = { [weak self] wave, hitsThisWave in
            Task { @MainActor in
                self?.handleHordeBenchmarkPlayerDeath(
                    wave: wave,
                    hitsThisWave: hitsThisWave
                )
            }
        }

        jockController.onBenchmarkEnemyKilled = { [weak self] id, wave in
            Task { @MainActor in
                self?.handleBenchmarkEnemyKilled(
                    id: id,
                    wave: wave
                )
            }
        }

        jockController.onBenchmarkEnemyDeathAnimationFinished = { [weak self] id, wave in
            Task { @MainActor in
                self?.handleBenchmarkEnemyDeathAnimationFinished(
                    id: id,
                    wave: wave
                )
            }
        }

        jockController.onAttackStarted = {
            print("[Gravitas Attack] Attack animation started.")
        }
    }

    func handle(_ envelope: PlagueDemoSession.CommandEnvelope) {
        guard !handledCommandIDs.contains(envelope.id) else { return }

        guard sceneRoot != nil else {
            pendingCommands.append(envelope)
            return
        }

        handledCommandIDs.insert(envelope.id)
        perform(envelope.command)
    }

    private func perform(_ command: PlagueDemoSession.Command) {
        switch command {
        case .startJockRetargetTest:
            Task {
                await startJockRetargetTest(autoPlayLoop: false)
            }

        case .playJockPacingLoop:
            Task {
                await startJockRetargetTest(autoPlayLoop: true)
            }

        case .playJockFollowDemo:
            Task {
                await startJockRetargetTest(autoPlayLoop: false)
                beginHordeRoomScanForBenchmark()
            }

        case .stopJockFollowDemo:
            stopHordeBenchmark()
            jockRetargetController?.stopFollowDemo()

        case .playJockClip(let clipID, let loop):
            do {
                try jockRetargetController?.playClip(
                    id: clipID,
                    loop: loop
                )
            } catch {
                assertionFailure("Failed to play JockAsset clip \(clipID): \(error)")
            }

        case .stopJockClip:
            jockRetargetController?.stopFollowDemo()
            jockRetargetController?.stopClip()

        case .resetJockPose:
            jockRetargetController?.resetPose()

        case .prepareForUserQuitOrClose:
            prepareForUserQuitOrClose()

        case .closeDemo:
            prepareForUserQuitOrClose()

        case .startHordeRoomScanOnly:
            beginHordeRoomScanForBenchmark()

        case .startRoomSkinningScan:
            roomSkinningCoordinator.startRoomSkinning()

        case .confirmRoomSkinningPlacement:
            roomSkinningCoordinator.confirmRoomSkinning()

        case .enterRoomSkinningDoorAdjustment:
            roomSkinningCoordinator.enterDoorAdjustment()

        case .confirmRoomSkinningDoorAdjustment:
            roomSkinningCoordinator.confirmDoorPlacement()

        case .cancelRoomSkinning:
            roomSkinningCoordinator.cancelRoomSkinning()

        case .updatePortalHDRIAtmosphere(let atmosphere):
            roomSkinningCoordinator.updatePortalContentAtmosphere(atmosphere)

        case .updatePortalLoopGainDB(let gainDB):
            hordePortalManager.updatePortalLoopGainDB(gainDB)

        case .updateEnemyCollisionDebugVisible(let visible):
            setEnemyCollisionDebugVisible(visible)
        }
    }

    func setEnemyCollisionDebugVisible(
        _ visible: Bool
    ) {
        for enemy in hordeEnemyControllersByID.values {
            enemy.bodyCollisionBox?.setDebugVisible(
                visible,
                state: enemy.enemyCollisionState
            )
        }

        print("[EnemyCollision] debug toggle \(visible)")
    }

    private func buildCrowdSnapshots(
        enemies: [JockRetargetTestController],
        headsetPosition: SIMD3<Float>
    ) -> [HordeEnemyCollisionSnapshot] {
        enemies.compactMap {
            HordeEnemyCollisionSnapshotBuilder.makeSnapshot(
                controller: $0,
                headsetPosition: headsetPosition
            )
        }
    }

    private var liveHordeEnemyControllers: [JockRetargetTestController] {
        hordeEnemyControllersByID.values.filter {
            $0.hordeLifecycleState.isLivingGameplayEnemy
        }
    }

    private func makeFrameClockSnapshot(
        date: Date,
        deltaTime: Float
    ) -> FrameClockSnapshot {
        let snapshot = FrameClockSnapshot(
            frameIndex: architectureFrameIndex,
            time: date.timeIntervalSinceReferenceDate,
            deltaTime: deltaTime
        )

        #if DEBUG
        MainActorSnapshotDebugAssertions.assertValueOnlySnapshot(snapshot)
        #endif

        return snapshot
    }

    private func makePlayerPoseSnapshot(
        from pose: PhaseOneSpawnPose
    ) -> PlayerPoseSnapshot {
        let forward = PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(pose.headForward.x, 0, pose.headForward.z),
            fallback: SIMD3<Float>(0, 0, -1)
        )

        let snapshot = PlayerPoseSnapshot(
            position: pose.headPosition,
            forward: forward,
            yawRadians: PhaseOneMath.yawRadiansForNegativeZForward(
                worldForward: forward
            )
        )

        #if DEBUG
        MainActorSnapshotDebugAssertions.assertValueOnlySnapshot(snapshot)
        #endif

        return snapshot
    }

    private func captureEnemyBodySnapshots(
        headsetPosition: SIMD3<Float>
    ) -> [EnemyBodySnapshot] {
        liveHordeEnemyControllers.compactMap {
            $0.makeEnemyBodySnapshot(
                headsetPosition: headsetPosition
            )
        }
    }

    private func captureEnemyBrainSnapshots(
        headsetPosition: SIMD3<Float>
    ) -> [EnemyBrainSnapshot] {
        liveHordeEnemyControllers.map {
            $0.makeEnemyBrainSnapshot(
                headsetPosition: headsetPosition
            )
        }
    }

    private func capturePortalRuntimeSnapshots() -> [PortalRuntimeSnapshot] {
        hordePortalManager.makePortalRuntimeSnapshots()
    }

    private func clearArchitectureSnapshots() {
        latestPlayerPoseSnapshot = nil
        latestEnemyBodySnapshots = []
        latestEnemyBrainSnapshots = []
        latestPortalRuntimeSnapshots = []
    }

    private func updateTimingProfilerCounters() {
        timingProfiler.setCounter(
            "enemy.count",
            liveHordeEnemyControllers.count
        )
        timingProfiler.setCounter(
            "portal.count",
            hordePortalManager.portals.count
        )
        timingProfiler.setCounter(
            "portal.fx.transition.count",
            hordePortalManager.activeTransitionFXCount
        )
        timingProfiler.setCounter(
            "portal.fx.glyph.count",
            hordePortalManager.activeGlyphFXCount
        )
        timingProfiler.setCounter(
            "portal.fx.active.count",
            hordePortalManager.activeTransitionFXCount +
                hordePortalManager.activeGlyphFXCount
        )
        timingProfiler.setCounter(
            "portal.ember.active.count",
            hordePortalManager.activeEmberCount
        )
        timingProfiler.setCounter(
            "audio.one_shot.active.count",
            audioController.activeSpatialOneShotCountForProfiling
        )
        timingProfiler.setCounter(
            "joint.count",
            liveHordeEnemyControllers.reduce(0) {
                $0 + $1.runtimeJointCountForProfiling
            }
        )
        timingProfiler.setCounter(
            "horde.ingress.active.count",
            activeIngressControllers.count
        )
        timingProfiler.setCounter(
            "snapshot.enemy_body.count",
            latestEnemyBodySnapshots.count
        )
        timingProfiler.setCounter(
            "snapshot.enemy_brain.count",
            latestEnemyBrainSnapshots.count
        )
        timingProfiler.setCounter(
            "snapshot.portal_runtime.count",
            latestPortalRuntimeSnapshots.count
        )
        timingProfiler.setCounter(
            "brain.in_flight.count",
            hordeBrainInFlight ? 1 : 0
        )
        timingProfiler.setCounter(
            "brain.command.pending.count",
            pendingHordeBrainCommands?.commands.count ?? 0
        )
    }

    private func applyCompletedHordeSimulationCommandsIfAvailable() {
        guard let commands = pendingHordeSimulationCommands else {
            return
        }

        pendingHordeSimulationCommands = nil

        timingProfiler.measure("simulation.apply") {
            for command in commands.steering {
                guard let enemy = hordeEnemyControllersByID[command.enemyID] else {
                    continue
                }

                guard enemy.hordeLifecycleState.isLivingGameplayEnemy else {
                    print(
                        """
                        [HordeLifecycle] skipped steering command for non-living enemy
                          enemyID: \(command.enemyID)
                          lifecycle: \(enemy.hordeLifecycleState.rawValue)
                        """
                    )
                    continue
                }

                enemy.applyCrowdSteeringCommand(command)
            }

            for command in commands.separation {
                guard let enemy = hordeEnemyControllersByID[command.enemyID] else {
                    continue
                }

                guard enemy.hordeLifecycleState == .active else {
                    print(
                        """
                        [HordeLifecycle] skipped separation command for non-active enemy
                          enemyID: \(command.enemyID)
                          lifecycle: \(enemy.hordeLifecycleState.rawValue)
                        """
                    )
                    continue
                }

                enemy.applyEnemySeparationCorrection(
                    command.correctionWorld
                )
            }
        }
    }

    private func applyCompletedHordeBrainCommandsIfAvailable() {
        guard let commandBuffer = pendingHordeBrainCommands else {
            return
        }

        pendingHordeBrainCommands = nil

        timingProfiler.measure("brain.apply") {
            for command in commandBuffer.commands {
                let enemyID: UUID

                switch command {
                case .enterCloseRangeReady(let id, _, _),
                     .setCloseRangeDelay(let id, _),
                     .startAttack(let id, _),
                     .exitCloseRangeToFollow(let id),
                     .clearAttackAnchor(let id),
                     .advanceActiveAttackElapsed(let id, _):
                    enemyID = id
                }

                guard let enemy = hordeEnemyControllersByID[enemyID] else {
                    continue
                }

                guard enemy.hordeLifecycleState == .active else {
                    print(
                        """
                        [HordeLifecycle] skipped brain command for non-active enemy
                          enemyID: \(enemyID)
                          lifecycle: \(enemy.hordeLifecycleState.rawValue)
                        """
                    )
                    continue
                }

                enemy.applyEnemyBrainCommand(command)
            }
        }
    }

    private func submitHordeSimulationIfIdle() {
        guard !hordeSimulationInFlight,
              let frame = latestFrameClockSnapshot,
              let player = latestPlayerPoseSnapshot else {
            return
        }

        let enemyBodies = latestEnemyBodySnapshots
        let enemyBrains = latestEnemyBrainSnapshots

        guard !enemyBodies.isEmpty,
              !enemyBrains.isEmpty else {
            return
        }

        hordeSimulationInFlight = true

        let engine = hordeSimulationEngine

        hordeSimulationTask = Task { [weak self] in
            let commands = await engine.stepCrowd(
                frame: frame,
                player: player,
                enemies: enemyBodies,
                brain: enemyBrains
            )

            await MainActor.run { [weak self] in
                guard let self else {
                    return
                }

                guard !Task.isCancelled else {
                    self.hordeSimulationInFlight = false
                    self.hordeSimulationTask = nil
                    return
                }

                self.pendingHordeSimulationCommands = commands
                self.hordeSimulationInFlight = false
                self.hordeSimulationTask = nil
            }
        }
    }

    private func submitHordeBrainIfIdle() {
        guard !hordeBrainInFlight,
              let frame = latestFrameClockSnapshot,
              let player = latestPlayerPoseSnapshot else {
            return
        }

        let enemyBrains = latestEnemyBrainSnapshots

        guard !enemyBrains.isEmpty else {
            return
        }

        hordeBrainInFlight = true

        let engine = hordeEnemyBrainEngine

        hordeBrainTask = Task { [weak self] in
            let commands = await engine.step(
                frame: frame,
                player: player,
                enemies: enemyBrains
            )

            await MainActor.run { [weak self] in
                guard let self else {
                    return
                }

                guard !Task.isCancelled else {
                    self.hordeBrainInFlight = false
                    self.hordeBrainTask = nil
                    return
                }

                self.pendingHordeBrainCommands = commands
                self.hordeBrainInFlight = false
                self.hordeBrainTask = nil
            }
        }
    }

    private func resetHordeSimulationPipeline() {
        hordeSimulationTask?.cancel()
        hordeSimulationTask = nil
        hordeSimulationInFlight = false
        pendingHordeSimulationCommands = nil
        hordeBrainTask?.cancel()
        hordeBrainTask = nil
        hordeBrainInFlight = false
        pendingHordeBrainCommands = nil

        let engine = hordeSimulationEngine

        Task {
            await engine.reset()
        }
    }

    func tick(at date: Date) {
        let tickStart = TimingProfiler.now()
        let deltaTime: Float

        if let lastTickDate {
            deltaTime = min(Float(date.timeIntervalSince(lastTickDate)), 0.1)
        } else {
            deltaTime = 1.0 / 60.0
        }

        lastTickDate = date

        architectureFrameIndex += 1
        latestFrameClockSnapshot = makeFrameClockSnapshot(
            date: date,
            deltaTime: deltaTime
        )

        defer {
            updateTimingProfilerCounters()
            timingProfiler.record(
                "coordinator.tick",
                startTime: tickStart
            )
            timingProfiler.printSummaryIfNeeded()
        }

        let currentPose = timingProfiler.measure("spatial.current_pose") {
            spatialProvider.currentPose()
        }
        let currentHeadPosition = currentPose?.headPosition

        if let currentPose {
            latestPlayerPoseSnapshot = timingProfiler.measure("snapshot.player_pose") {
                makePlayerPoseSnapshot(
                    from: currentPose
                )
            }

            roomSkinningCoordinator.updatePlayerPose(
                position: currentPose.headPosition,
                forward: currentPose.headForward
            )

            updateHordeRoomScanIfNeeded(
                currentPose: currentPose
            )

            updateWallPosterUIIfNeeded(
                currentPose: currentPose,
                date: date
            )
        } else {
            clearArchitectureSnapshots()
        }

        #if DEBUG
        assertNoVisibleEnemyBeforeFirstPortal()
        #endif

        if hordeBenchmarkRunning {
            applyCompletedHordeSimulationCommandsIfAvailable()
            applyCompletedHordeBrainCommandsIfAvailable()

            if let pose = currentPose {
                timingProfiler.measure("portal.ingress.update") {
                    updatePortalIngressControllers(
                        deltaTime: deltaTime,
                        playerWorldPosition: pose.headPosition
                    )
                }
            }

            timingProfiler.measure("portal.fx.update") {
                hordePortalManager.updatePortalFX(
                    deltaTime: deltaTime,
                    timingProfiler: timingProfiler
                )
            }

            for controller in hordeEnemyControllersByID.values {
                guard controller.hordeLifecycleState.isLivingGameplayEnemy else {
                    print(
                        """
                        [HordeLifecycle] ERROR non-living enemy found in active update map
                          enemyID: \(controller.hordeBenchmarkID.uuidString)
                          lifecycle: \(controller.hordeLifecycleState.rawValue)
                        """
                    )
                    continue
                }

                timingProfiler.measure("enemy.update") {
                    controller.update(
                        deltaTime: deltaTime,
                        currentHeadPosition: currentHeadPosition,
                        timingProfiler: timingProfiler
                    )
                }
            }

            updateDyingHordeEnemies(
                deltaTime: deltaTime,
                currentHeadPosition: currentHeadPosition
            )

            if let pose = currentPose {
                latestEnemyBodySnapshots = timingProfiler.measure("snapshot.enemy_body_value") {
                    captureEnemyBodySnapshots(
                        headsetPosition: pose.headPosition
                    )
                }
                latestEnemyBrainSnapshots = timingProfiler.measure("snapshot.enemy_brain_value") {
                    captureEnemyBrainSnapshots(
                        headsetPosition: pose.headPosition
                    )
                }
                latestPortalRuntimeSnapshots = timingProfiler.measure("snapshot.portal_runtime_value") {
                    capturePortalRuntimeSnapshots()
                }

                submitHordeSimulationIfIdle()
                submitHordeBrainIfIdle()
            } else {
                latestEnemyBodySnapshots = []
                latestEnemyBrainSnapshots = []
                latestPortalRuntimeSnapshots = []
            }

            #if DEBUG
            if let sceneRoot {
                for child in sceneRoot.children where child.name.hasPrefix("Horde_") {
                    let isRegistered = isKnownHordeRootEntity(child)

                    if child.isEnabled, !isRegistered {
                        print(
                            """
                            [Horde] ERROR visible horde entity is not registered
                              entity: \(child.name)
                              thisCanCauseAPose: true
                            """
                        )
                    }
                }
            }
            #endif
        } else {
            latestEnemyBodySnapshots = []
            latestEnemyBrainSnapshots = []
            latestPortalRuntimeSnapshots = []

            if let controller = jockRetargetController {
                timingProfiler.measure("enemy.update.single") {
                    controller.update(
                        deltaTime: deltaTime,
                        currentHeadPosition: currentHeadPosition,
                        timingProfiler: timingProfiler
                    )
                }
            }
        }
    }

    func shutdown() {
        stopHordeBenchmark()
        roomSkinningCoordinator.cancelRoomSkinning()
        jockRetargetController?.hide()
        spatialProvider.onPlaneAnchorUpdate = nil
        spatialProvider.stop()
        audioController.stopAllAudio()
        resetHordeBenchmarkDeathPresentation()
        forestEnvironmentController.shutdown()
        wallPosterUIController.reset()
        onWallPosterUIActiveChanged?(false)

        sceneRoot = nil
        headAnchor = nil
        jockRetargetController = nil
        lastWallPosterPlacementAttempt = nil
        lastTickDate = nil
        handledCommandIDs.removeAll()
        pendingCommands.removeAll()
    }

    private func prepareForUserQuitOrClose() {
        print(
            """
            [PlagueApp] immersive cleanup starting
              hordeRunning: \(hordeBenchmarkRunning)
              activeEnemies: \(activeHordeEnemyIDs.count)
              dyingEnemies: \(dyingHordeEnemyIDs.count)
              corpses: \(corpseHordeEnemyIDs.count)
              playerDeathActive: \(isPlayerDeathSequenceActive)
            """
        )

        stopHordeBenchmark()
        jockRetargetController?.stopFollowDemo()
        jockRetargetController?.stopClip()
        jockRetargetController?.hide()
        spatialProvider.stop()
        audioController.stopAllAudio()
        resetHordeBenchmarkDeathPresentation()

        hordeCurrentWave = 0
        hordePlayerHitsThisWave = 0
        hordeTotalSpawned = 0
        hordeTotalKilled = 0

        UserDefaults.standard.set(
            Date(),
            forKey: "lastExitDate"
        )

        print("[PlagueApp] cleanup complete; closing app/window.")
    }

    private func drainPendingCommands() {
        let commandsToDrain = pendingCommands
        pendingCommands.removeAll()

        for command in commandsToDrain {
            handle(command)
        }
    }

    private func startJockRetargetTest(autoPlayLoop: Bool) async {
        guard let jockRetargetController = ensureJockRetargetController() else {
            return
        }

        do {
            stopHordeBenchmark()
            resetHordeBenchmarkDeathPresentation()

            try await jockRetargetController.loadIfNeeded()

            let spawnPose = spatialProvider.currentPoseOrFallback()
            let config = PhaseOneConfiguration.phaseOneDefault

            let floorY = await spatialProvider.resolvedFloorY(
                for: spawnPose,
                fallbackHeadToFloorOffset: config.fallbackHeadToFloorOffset,
                timeoutSeconds: config.floorDetectionTimeoutSeconds
            )

            audioController.startDemoAudio(
                spawnPose: spawnPose,
                floorY: floorY
            )
            audioController.startPrimaryHostDadBreathing()

            jockRetargetController.configureSpawn(
                using: spawnPose,
                floorY: floorY
            )

            jockRetargetController.show()

            if autoPlayLoop {
                try jockRetargetController.playPacingLoopFromStart()
            }
        } catch {
            assertionFailure("Failed to start JockAsset Retarget Test: \(error)")
        }
    }

    private func beginHordeRoomScanForBenchmark() {
        guard !hordeWaitingForRoomScan else {
            print("[HordeRoomScan] Horde start ignored; scan already active")
            return
        }

        hordeRoomScanCompletionTask?.cancel()
        hordeRoomScanCompletionTask = nil
        pendingNextBenchmarkWaveTask?.cancel()
        pendingNextBenchmarkWaveTask = nil
        clearHordeEnemyControllers()
        activeIngressControllers.removeAll()
        hordePortalManager.reset()
        activeHordeEnemyIDs.removeAll()
        dyingHordeEnemyIDs.removeAll()
        corpseHordeEnemyIDs.removeAll()

        hordeBenchmarkRunning = false
        hordeWaitingForRoomScan = true
        hordeWaitingForFloorPromptShown = false
        hordeRuntimePhase = .waitingForRoomScan
        hordeWaveSpawnState = .idle
        hordeSpawnFailures.removeAll()
        isSpawningHordeWave = false
        nextGlobalEnemySpawnIndex = 0
        hordePrewarmTask?.cancel()
        hordePrewarmTask = nil
        hordePrewarmReady = false
        hordePrewarmCoordinator.releaseAll()
        scheduleInitialHordePrewarm(
            reason: "horde_room_scan_started"
        )
        hordeRoomScanTracker.begin()
        roomSkinningCoordinator.startHordeRoomScanOnly()

        startHordeRadioLoopUsingCurrentPose(
            reason: "horde_room_scan_started"
        )

        showInstructionHUD(
            "Spin around in a full 360 degree circle to scan the room."
        )

        print(
            """
            [Horde] start requested
              phase: \(hordeRuntimePhase.rawValue)
              enemyCreationAllowed: false
              waitingForFirstPortal: true
            """
        )
    }

    private func updateHordeRoomScanIfNeeded(
        currentPose: PhaseOneSpawnPose
    ) {
        guard hordeWaitingForRoomScan else {
            return
        }

        hordeRoomScanTracker.updateHeadForward(
            currentPose.headForward
        )

        let percent = Int(hordeRoomScanTracker.progress * 100)

        if percent >= 50,
           !hordeRoomScanTracker.isComplete {
            showInstructionHUD("Keep turning. The room is still being mapped. \(percent)%")
        } else if !hordeRoomScanTracker.isComplete {
            showInstructionHUD("Spin around in a full 360 degree circle to scan the room. \(percent)%")
        }

        if hordeRoomScanTracker.isComplete {
            finishHordeRoomScanAndStartBenchmark()
        }
    }

    private func finishHordeRoomScanAndStartBenchmark() {
        guard hordeWaitingForRoomScan else {
            return
        }

        guard roomSkinningCoordinator.wallManager.floorCandidates.values.contains(where: { $0.isUsableFloor }) else {
            showInstructionHUD(
                "Look down briefly. I need the floor before the breach can open."
            )

            if !hordeWaitingForFloorPromptShown {
                hordeWaitingForFloorPromptShown = true

                print(
                    """
                    [HordeRoomScan] scan has walls but no verified floor
                      action: waiting_for_floor
                    """
                )
            }

            return
        }

        hordeWaitingForRoomScan = false
        hordeWaitingForFloorPromptShown = false
        hordeRuntimePhase = .creatingFirstPortal

        hordeRoomScanCompletionTask?.cancel()
        hordeRoomScanCompletionTask = Task { @MainActor in
            showInstructionHUD("Walls mapped. Breach points forming.")

            try? await Task.sleep(
                nanoseconds: 1_000_000_000
            )

            guard !Task.isCancelled else {
                return
            }

            showInstructionHUD("Portal breach detected.")

            try? await Task.sleep(
                nanoseconds: 1_400_000_000
            )

            guard !Task.isCancelled else {
                return
            }

            let spawnPose = spatialProvider.currentPoseOrFallback()
            guard prepareWallPosterBeforeHordePortals(
                currentPose: spawnPose
            ) else {
                hordeRuntimePhase = .waitingForRoomScan
                hordeWaitingForRoomScan = true
                hordeRoomScanTracker.begin()

                showInstructionHUD(
                    "Look around slowly. I need a stable wall for the control panel before the breach can open."
                )

                print(
                    """
                    [Horde] first portal creation blocked
                      reason: wall_poster_occupancy_not_registered
                      enemyCreationAllowed: false
                      action: keep_scanning
                    """
                )

                return
            }

            let firstPortal = await hordePortalManager.createPortalForWave(
                wave: 1,
                spawnIndex: 0,
                playerPosition: spawnPose.headPosition,
                playerForward: spawnPose.headForward,
                excludingPortalIDs: []
            )

            guard firstPortal != nil else {
                hordeRuntimePhase = .waitingForRoomScan
                hordeWaitingForRoomScan = true
                hordeRoomScanTracker.begin()

                showInstructionHUD(
                    "Look around slowly. I need a wall and floor before the breach can open."
                )

                print(
                    """
                    [Horde] first portal creation failed
                      enemyCreationAllowed: false
                      action: keep_scanning
                    """
                )

                return
            }

            if let firstPortal {
                startHordeRadioLoopUsingCurrentPose(
                    floorY: firstPortal.resolvedFloorWorldY ?? firstPortal.placement.floorWorldY,
                    reason: "first_portal_floor_resolved"
                )
            }

            hordeRuntimePhase = .portalsReady

            print(
                """
                [Horde] first portal ready
                  phase: \(hordeRuntimePhase.rawValue)
                  enemyCreationAllowed: true
                  portalCount: \(hordePortalManager.portals.count)
                """
            )

            instructionHUD.clear()

            await startHordeBenchmark()
        }
    }

    private func startHordeRadioLoopUsingCurrentPose(
        floorY resolvedFloorY: Float? = nil,
        reason: String
    ) {
        guard let sceneRoot else {
            print(
                """
                [Gravitas Audio] Horde radio loop start skipped
                  reason: \(reason)
                  sceneRootAvailable: false
                """
            )
            return
        }

        let spawnPose = spatialProvider.currentPoseOrFallback()
        let config = PhaseOneConfiguration.phaseOneDefault
        let fallbackFloorY =
            spawnPose.headPosition.y - config.fallbackHeadToFloorOffset
        let floorY = resolvedFloorY ?? fallbackFloorY

        audioController.attachRadioToSceneIfNeeded(
            sceneRoot: sceneRoot
        )

        audioController.startHordeRadioLoop(
            spawnPose: spawnPose,
            floorY: floorY
        )

        print(
            """
            [Horde] radio loop active
              reason: \(reason)
              floorY: \(floorY)
              source: existing_spatial_radio
            """
        )
    }

    private func scheduleInitialHordePrewarm(
        reason: String
    ) {
        guard !hordePrewarmReady,
              hordePrewarmTask == nil else {
            return
        }

        hordePrewarmTask = Task { @MainActor [weak self] in
            guard let self else {
                return false
            }

            return await self.performInitialHordePrewarm(
                reason: reason
            )
        }
    }

    private func ensureInitialHordePrewarmReady(
        reason: String
    ) async -> Bool {
        if hordePrewarmReady {
            return true
        }

        if hordePrewarmTask == nil {
            scheduleInitialHordePrewarm(
                reason: reason
            )
        }

        guard let task = hordePrewarmTask else {
            return false
        }

        let result = await task.value
        hordePrewarmTask = nil

        return result
    }

    private func performInitialHordePrewarm(
        reason: String
    ) async -> Bool {
        if Task.isCancelled {
            return false
        }

        do {
            let enabledCharacters = try enabledHordeCharacterAttributes()

            hordePrewarmCoordinator.installCharacterAttributes(
                enabledCharacters
            )

            let plan = HordePrewarmPlanner.planForInitialHordeStart(
                enabledCharacters: enabledCharacters,
                preloadAllEnabledCharacters: true
            )

            try await hordePrewarmCoordinator.prewarm(
                plan: plan
            )

            hordePrewarmReady = true

            print(
                """
                [HordePrewarm] initial Horde prewarm complete
                  reason: \(reason)
                  preloadedAllEnabledCharacters: true
                  hordeCanSpawn: true
                """
            )

            return true
        } catch {
            hordePrewarmReady = false

            print(
                """
                [HordePrewarm] ERROR initial Horde prewarm failed
                  reason: \(reason)
                  error: \(error.localizedDescription)
                  fallback: false
                  hordeCanSpawn: false
                """
            )

            return false
        }
    }

    private func enabledHordeCharacterAttributes() throws -> [CharacterAttributes] {
        if !CharacterAttributeStore.shared.isLoaded {
            try CharacterAttributeStore.shared.loadStrict()
        }

        return CharacterAttributeStore.shared.attributesByID.values
            .filter {
                $0.horde.enabled
            }
            .sorted {
                $0.characterID < $1.characterID
            }
    }

    private func attributesByArchetypeForHordeLineup(
        _ lineup: [PlagueCharacterArchetype]
    ) throws -> [PlagueCharacterArchetype: CharacterAttributes] {
        var out: [PlagueCharacterArchetype: CharacterAttributes] = [:]

        for archetype in Set(lineup) {
            out[archetype] = try CharacterAttributeStore.shared.attributes(
                for: archetype
            )
        }

        return out
    }

    private func ensureWavePrewarmed(
        wave: Int,
        lineup: [PlagueCharacterArchetype]
    ) async -> Bool {
        do {
            let attributesByArchetype = try attributesByArchetypeForHordeLineup(
                lineup
            )

            hordePrewarmCoordinator.installCharacterAttributes(
                Array(attributesByArchetype.values)
            )

            let plan = HordePrewarmPlanner.planForWave(
                waveIndex: wave,
                lineup: lineup,
                attributesByArchetype: attributesByArchetype
            )

            try await hordePrewarmCoordinator.prewarm(
                plan: plan
            )

            return true
        } catch {
            print(
                """
                [HordePrewarm] ERROR wave prewarm failed
                  wave: \(wave)
                  error: \(error.localizedDescription)
                  fallback: false
                """
            )

            return false
        }
    }

    private func showInstructionHUD(
        _ text: String
    ) {
        guard let headAnchor else {
            print("[PlagueHUD] WARNING cannot show HUD; head anchor not ready")
            return
        }

        instructionHUD.show(
            text,
            on: headAnchor
        )
    }

    private func updatePortalIngressControllers(
        deltaTime: Float,
        playerWorldPosition: SIMD3<Float>
    ) {
        var finishedIDs: [UUID] = []

        for (enemyID, ingress) in activeIngressControllers {
            ingress.update(
                deltaTime: deltaTime,
                playerWorldPosition: playerWorldPosition
            )

            if ingress.consumeRoomVisualRevealEvent(),
               let controller = hordeEnemyControllersByID[enemyID] {
                audioController.attachHostAudioSource(
                    id: enemyID,
                    hostRootEntity: controller.rootEntity,
                    archetype: controller.archetype,
                    headAudioEntity: controller.characterAudioEmitter,
                    breathingStartDelay: 0
                )

                print(
                    """
                    [HordePortalIngress] character loop audio started at room visual reveal
                      enemyID: \(enemyID)
                      archetype: \(controller.archetype.rawValue)
                      parent: enemyRoot
                      delay: 0.000
                    """
                )
            }

            switch ingress.phase {
            case .realWorldFollowing:
                finishedIDs.append(enemyID)

            case .failed:
                finishedIDs.append(enemyID)

            case .walkingParallelInsidePortal,
                 .turningTowardExit,
                 .crossingAperture:
                break
            }
        }

        for enemyID in finishedIDs {
            activeIngressControllers.removeValue(forKey: enemyID)
        }
    }

    private func updateDyingHordeEnemies(
        deltaTime: Float,
        currentHeadPosition: SIMD3<Float>?
    ) {
        let dyingControllers = Array(hordeDyingEnemyControllersByID.values)

        for controller in dyingControllers {
            guard hordeDyingEnemyControllersByID[controller.hordeBenchmarkID] != nil else {
                continue
            }

            controller.update(
                deltaTime: deltaTime,
                currentHeadPosition: currentHeadPosition,
                timingProfiler: timingProfiler
            )
        }
    }

    #if DEBUG
    private func isKnownHordeRootEntity(
        _ entity: Entity
    ) -> Bool {
        hordeEnemyControllersByID.values.contains { controller in
            controller.rootEntity === entity
        } ||
            hordeDyingEnemyControllersByID.values.contains { controller in
                controller.rootEntity === entity
            } ||
            hordeCorpseRecordsByID.values.contains { record in
                record.rootEntity === entity
            }
    }

    private func assertNoVisibleEnemyBeforeFirstPortal() {
        guard !hordePortalSystemReady else {
            return
        }

        for controller in hordeEnemyControllersByID.values {
            if controller.rootEntity.parent != nil ||
                controller.rootEntity.isEnabled {
                print(
                    """
                    [Horde] ERROR visible enemy before first portal
                      enemyID: \(controller.hordeBenchmarkID.uuidString)
                      phase: \(hordeRuntimePhase.rawValue)
                      parent: \(controller.rootEntity.parent?.name ?? "nil")
                      isEnabled: \(controller.rootEntity.isEnabled)
                      likelySymptom: A_pose_before_room_skinning
                    """
                )
            }
        }
    }
    #endif

    private func updateWallPosterUIIfNeeded(
        currentPose: PhaseOneSpawnPose,
        date: Date
    ) {
        if wallPosterUIController.isPlaced {
            wallPosterUIController.refreshTransformForWallUpdate()
            return
        }

        if let lastWallPosterPlacementAttempt,
           date.timeIntervalSince(lastWallPosterPlacementAttempt) < 2.0 {
            return
        }

        lastWallPosterPlacementAttempt = date

        let didPlace = wallPosterUIController.placeOnBestWall(
            playerPosition: currentPose.headPosition,
            playerForward: currentPose.headForward
        )

        guard didPlace else {
            return
        }

        wallPosterUIController.lockPlacement()
        forestEnvironmentController.applyIBLReceiverRecursively(
            root: wallPosterUIController.root
        )
        onWallPosterUIActiveChanged?(true)
    }

    private func prepareWallPosterBeforeHordePortals(
        currentPose: PhaseOneSpawnPose
    ) -> Bool {
        if wallPosterUIController.isPlaced {
            wallPosterUIController.lockPlacement()

            guard wallPosterUIController.hasRegisteredOccupancy else {
                print(
                    """
                    [Horde] FATAL portal creation attempted before poster occupancy
                      action: block_first_portal_creation
                    """
                )

                return false
            }

            print(
                """
                [Horde] wall poster ready before portal creation
                  occupancyRegistered: true
                """
            )

            return true
        }

        let didPlace = wallPosterUIController.placeOnBestWall(
            playerPosition: currentPose.headPosition,
            playerForward: currentPose.headForward,
            force: false
        )

        guard didPlace else {
            print(
                """
                [WallPosterUI] failed to reserve occupancy before first portal
                  portalPlacementMayProceed: false
                """
            )

            return false
        }

        wallPosterUIController.lockPlacement()

        guard wallPosterUIController.hasRegisteredOccupancy else {
            print(
                """
                [Horde] ERROR wall poster occupancy not registered
                  action: block_first_portal_creation
                """
            )

            return false
        }

        forestEnvironmentController.applyIBLReceiverRecursively(
            root: wallPosterUIController.root
        )
        onWallPosterUIActiveChanged?(true)

        print(
            """
            [Horde] wall poster ready before portal creation
              occupancyRegistered: true
            """
        )

        return true
    }

    private func startHordeBenchmark() async {
        guard sceneRoot != nil else { return }

        guard hordePortalSystemReady else {
            print(
                """
                [Horde] spawnNextHordeWave blocked
                  phase: \(hordeRuntimePhase.rawValue)
                  portalCount: \(hordePortalManager.portals.count)
                  reason: no_first_portal_yet
                  enemyCreationAllowed: false
                """
            )
            return
        }

        pendingNextBenchmarkWaveTask?.cancel()
        pendingNextBenchmarkWaveTask = nil
        clearHordeEnemyControllers()
        activeIngressControllers.removeAll()
        activeHordeEnemyIDs.removeAll()
        dyingHordeEnemyIDs.removeAll()
        corpseHordeEnemyIDs.removeAll()

        resetHordeBenchmarkDeathPresentation()

        hordeBenchmarkRunning = true
        hordeCurrentWave = 0
        hordePlayerHitsThisWave = 0
        hordeTotalSpawned = 0
        hordeTotalKilled = 0
        nextGlobalEnemySpawnIndex = 0
        hordeWaveSpawnState = .idle
        hordeSpawnFailures.removeAll()
        isSpawningHordeWave = false
        hordeScoresSubmittedForCurrentRun = false

        jockRetargetController?.hide()
        audioController.stopPrimaryHostDadBreathing()
        audioController.startHordeMusicSequence()

        await spawnNextHordeWave()
    }

    private func stopHordeBenchmark() {
        submitHordeScoresIfNeeded(
            reason: "horde_stopped"
        )

        pendingNextBenchmarkWaveTask?.cancel()
        pendingNextBenchmarkWaveTask = nil
        hordeRoomScanCompletionTask?.cancel()
        hordeRoomScanCompletionTask = nil
        resetHordeSimulationPipeline()
        hordePrewarmTask?.cancel()
        hordePrewarmTask = nil
        hordePrewarmReady = false
        hordePrewarmCoordinator.releaseAll()

        hordeBenchmarkRunning = false
        hordeRuntimePhase = .idle
        hordeWaitingForRoomScan = false
        hordeWaitingForFloorPromptShown = false
        hordeRoomScanTracker.cancel()
        instructionHUD.clear()
        audioController.stopHordeMusicSequence()
        audioController.stopDemoAudio()
        activeIngressControllers.removeAll()
        hordePortalManager.reset()
        clearHordeEnemyControllers()
        activeHordeEnemyIDs.removeAll()
        dyingHordeEnemyIDs.removeAll()
        corpseHordeEnemyIDs.removeAll()
        hordePlayerHitsThisWave = 0
        hordeWaveSpawnState = .idle
        hordeSpawnFailures.removeAll()
        isSpawningHordeWave = false
    }

    private func submitHordeScoresIfNeeded(
        reason: String
    ) {
        guard !hordeScoresSubmittedForCurrentRun else {
            return
        }

        guard hordeCurrentWave > 0 ||
            hordeTotalSpawned > 0 ||
            hordeTotalKilled > 0 else {
            return
        }

        hordeScoresSubmittedForCurrentRun = true

        print(
            """
            [HordeLeaderboards] session end submit requested
              reason: \(reason)
              currentWave: \(hordeCurrentWave)
              totalSpawned: \(hordeTotalSpawned)
              totalKilled: \(hordeTotalKilled)
            """
        )

        onHordeSessionEnded?()
    }

    private func spawnNextHordeWave() async {
        guard !isSpawningHordeWave else {
            print("[Horde] spawnNextHordeWave ignored: already spawning")
            return
        }

        guard hordeBenchmarkRunning else {
            print("[HordeBenchmark] spawnNextWave ignored: benchmark not running")
            return
        }

        guard hordePortalSystemReady else {
            print(
                """
                [Horde] spawnNextHordeWave blocked
                  phase: \(hordeRuntimePhase.rawValue)
                  portalCount: \(hordePortalManager.portals.count)
                  reason: no_first_portal_yet
                  enemyCreationAllowed: false
                """
            )
            return
        }

        guard !isPlayerDeathSequenceActive else {
            print("[HordeBenchmark] spawnNextWave ignored: player dead")
            return
        }

        guard sceneRoot != nil else { return }

        cleanupHordeCorpsesForWaveTransition(
            reason: "before_spawn_next_wave"
        )
        assertNoCorpseInActiveEnemyMap()

        guard activeHordeEnemyIDs.isEmpty,
              dyingHordeEnemyIDs.isEmpty else {
            print(
                """
                [Horde] ERROR spawn requested while current wave still has live/dying enemies
                  currentWave: \(hordeCurrentWave)
                  active: \(activeHordeEnemyIDs.count)
                  dying: \(dyingHordeEnemyIDs.count)
                  waveState: \(hordeWaveSpawnState.rawValue)
                """
            )
            return
        }

        isSpawningHordeWave = true
        hordeRuntimePhase = .spawningWave
        defer {
            isSpawningHordeWave = false
        }

        let spawnPose = spatialProvider.currentPoseOrFallback()
        let config = PhaseOneConfiguration.phaseOneDefault

        let floorY = await spatialProvider.resolvedFloorY(
            for: spawnPose,
            fallbackHeadToFloorOffset: config.fallbackHeadToFloorOffset,
            timeoutSeconds: config.floorDetectionTimeoutSeconds
        )

        let nextWave = hordeCurrentWave + 1
        let lineup = HordeCharacterWaveLineup.lineup(wave: nextWave)
        let spawnCount = lineup.count

        guard await ensureWavePrewarmed(
            wave: nextWave,
            lineup: lineup
        ) else {
            hordeWaveSpawnState = .failed
            hordeRuntimePhase = .portalsReady

            print(
                """
                [HordeSpawn] blocked because wave prewarm failed
                  wave: \(nextWave)
                  fallback: false
                """
            )

            return
        }

        let positions = hordeSpawnPositions(
            count: spawnCount,
            spawnPose: spawnPose,
            floorY: floorY
        )

        guard positions.count == spawnCount else {
            print(
                """
                [HordeBenchmark] ERROR spawn position count mismatch
                  wave: \(nextWave)
                  lineupCount: \(spawnCount)
                  positions: \(positions.count)
                """
            )
            hordeWaveSpawnState = .failed
            return
        }

        hordeWaveSpawnState = .spawning
        hordeSpawnFailures.removeAll()
        hordePlayerHitsThisWave = 0

        let spawnRequests = lineup.map { archetype in
            (
                id: UUID(),
                archetype: archetype
            )
        }
        let spawnIndexByID = Dictionary(
            uniqueKeysWithValues: spawnRequests.enumerated().map { index, request in
                (
                    request.id,
                    index
                )
            }
        )
        let hitsToKillByID: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: spawnRequests.compactMap { request in
                let attributes: CharacterAttributes

                do {
                    attributes = try CharacterAttributeStore.shared.attributes(
                        for: request.archetype
                    )
                } catch {
                    handleHordeSpawnFailure(
                        HordeSpawnFailureRecord(
                            wave: nextWave,
                            spawnIndex: spawnIndexByID[request.id] ?? 0,
                            archetype: request.archetype,
                            reason: error.localizedDescription
                        )
                    )

                    print(
                        """
                        [HordeSpawn] ERROR character attributes missing
                          archetype: \(request.archetype.rawValue)
                          error: \(error.localizedDescription)
                          noFallback: true
                        """
                    )

                    return nil
                }

                let hitsToKill = attributes.horde.hitsToKill.random()

                print(
                    """
                    [HordeSpawn] character attributes selected
                      archetype: \(request.archetype.rawValue)
                      characterID: \(attributes.characterID)
                      hitsToKill: \(hitsToKill)
                      usdz: \(attributes.asset.usdz)
                      range: \(attributes.horde.hitsToKill.min)-\(attributes.horde.hitsToKill.max)
                      noFallback: true
                    """
                )

                return (
                    request.id,
                    hitsToKill
                )
            }
        )
        let assignments = await HordePortalWaveAssignmentPlanner(
            portalManager: hordePortalManager
        )
        .buildAssignmentsForWave(
            wave: nextWave,
            spawnRequests: spawnRequests,
            playerPosition: spawnPose.headPosition,
            playerForward: spawnPose.headForward
        )

        guard !assignments.isEmpty else {
            hordeWaveSpawnState = .failed
            hordeRuntimePhase = .portalsReady

            print(
                """
                [HordePortal] ERROR no portal available for wave
                  wave: \(nextWave)
                  directRoomSpawnAllowed: false
                  wallCandidates: \(roomSkinningCoordinator.wallManager.wallCandidates.count)
                """
            )

            return
        }

        let assignedIDs = Set(assignments.map(\.enemyID))
        for request in spawnRequests where !assignedIDs.contains(request.id) {
            let index = spawnIndexByID[request.id] ?? 0
            handleHordeSpawnFailure(
                HordeSpawnFailureRecord(
                    wave: nextWave,
                    spawnIndex: index,
                    archetype: request.archetype,
                    reason: "No portal assignment available"
                )
            )
        }

        showInstructionHUD("Wave \(nextWave). They are coming through.")
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: 2_200_000_000
            )

            guard hordeBenchmarkRunning,
                  hordeCurrentWave == nextWave else {
                return
            }

            instructionHUD.clear()
        }

        print(
            """
            [Horde] wave spawn started
              wave: \(nextWave)
              requestedCount: \(spawnCount)
              lineup: \(lineup.map { $0.rawValue }.joined(separator: ", "))
            """
        )

        var successfulSpawnCount = 0

        for assignment in assignments {
            let index = spawnIndexByID[assignment.enemyID] ?? successfulSpawnCount
            let archetype = assignment.archetype
            let id = assignment.enemyID
            let collisionSpawnIndex = nextGlobalEnemySpawnIndex
            nextGlobalEnemySpawnIndex += 1

            guard let hitsToKill = hitsToKillByID[id] else {
                handleHordeSpawnFailure(
                    HordeSpawnFailureRecord(
                        wave: nextWave,
                        spawnIndex: index,
                        archetype: archetype,
                        reason: "Missing sidecar-derived hitsToKill"
                    )
                )

                print(
                    """
                    [HordeSpawn] ERROR missing sidecar-derived hitsToKill
                      archetype: \(archetype.rawValue)
                      enemyID: \(id)
                      noFallback: true
                    """
                )
                continue
            }

            do {
                guard let portal = hordePortalManager.portals[assignment.portalID] else {
                    throw NSError(
                        domain: "HordePortal",
                        code: 501,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Assigned Horde portal missing \(assignment.portalID)."
                        ]
                    )
                }

                let controller = try await createLoadedHordeEnemyController(
                    id: id,
                    archetype: archetype,
                    position: positions[index],
                    wave: nextWave,
                    spawnIndex: collisionSpawnIndex,
                    hitsToKill: hitsToKill,
                    playerHeadPosition: spawnPose.headPosition
                )
                guard hordeBenchmarkRunning,
                      !isPlayerDeathSequenceActive else {
                    controller.hide()
                    recycleHordePrewarmedAssets(
                        from: controller
                    )
                    print(
                        """
                        [Horde] spawn cancelled before reveal
                          wave: \(nextWave)
                          index: \(index)
                          archetype: \(archetype.rawValue)
                          benchmarkRunning: \(hordeBenchmarkRunning)
                          playerDeathActive: \(isPlayerDeathSequenceActive)
                        """
                    )
                    return
                }

                try registerHordeEnemyForInstancedPortalIngress(
                    controller: controller,
                    id: id,
                    archetype: archetype,
                    wave: nextWave,
                    spawnIndex: index,
                    portal: portal,
                    side: assignment.side,
                    assignmentKind: assignment.assignmentKind,
                    currentHeadPosition: spatialProvider.currentPose()?.headPosition ?? spawnPose.headPosition
                )

                hordePortalManager.markEntranceUsed(
                    portalID: portal.id
                )

                if successfulSpawnCount == 0 {
                    hordeCurrentWave = nextWave
                    onHordeWaveReached?(
                        nextWave
                    )
                }

                successfulSpawnCount += 1
                hordeTotalSpawned += 1

                print(
                    """
                    [Horde] enemy spawned and registered
                      wave: \(nextWave)
                      index: \(index)
                      archetype: \(archetype.rawValue)
                      id: \(id)
                      hitsToKill: \(hitsToKill)
                      portalID: \(portal.id)
                      side: \(assignment.side.rawValue)
                      assignmentKind: \(assignment.assignmentKind.rawValue)
                      activeIDs: \(activeHordeEnemyIDs.count)
                      controllers: \(hordeEnemyControllersByID.count)
                    """
                )
            } catch {
                let attributes = try? CharacterAttributeStore.shared.attributes(
                    for: archetype
                )
                let assetFile = attributes?.asset.usdz ?? "attribute_missing"
                let posePolicy = attributes?.runtime.poseApplicationPolicy.rawValue ?? "attribute_missing"

                handleHordeSpawnFailure(
                    HordeSpawnFailureRecord(
                        wave: nextWave,
                        spawnIndex: index,
                        archetype: archetype,
                        reason: error.localizedDescription
                    )
                )

                print(
                    """
                    [Horde] ERROR enemy spawn failed
                      wave: \(nextWave)
                      index: \(index)
                      archetype: \(archetype.rawValue)
                      file: \(assetFile)
                      policy: \(posePolicy)
                      id: \(id)
                      reason: \(error.localizedDescription)
                      noFallback: true
                      alreadySpawnedEnemiesRemainAlive: true
                      waveWillNotResetToOne: true
                    """
                )
            }
        }

        if successfulSpawnCount == 0 {
            hordeWaveSpawnState = .failed
            hordeRuntimePhase = .portalsReady

            print(
                """
                [Horde] ERROR wave spawn failed completely
                  wave: \(nextWave)
                  requestedCount: \(spawnCount)
                  successfulSpawnCount: 0
                  failures: \(hordeSpawnFailures.map { "\($0.spawnIndex):\($0.archetype.rawValue):\($0.reason)" }.joined(separator: " | "))
                  currentWavePreserved: \(hordeCurrentWave)
                  noResetToWaveOne: true
                """
            )

            return
        }

        hordeWaveSpawnState = hordeSpawnFailures.isEmpty ? .active : .degraded
        hordeRuntimePhase = .activeWave

        print(
            """
            [Horde] wave spawn complete
              wave: \(nextWave)
              requestedCount: \(spawnCount)
              successfulSpawnCount: \(successfulSpawnCount)
              failureCount: \(hordeSpawnFailures.count)
              state: \(hordeWaveSpawnState.rawValue)
              activeEnemyIDs: \(activeHordeEnemyIDs.count)
              controllers: \(hordeEnemyControllersByID.count)
              aliveEnemies: \(activeHordeEnemyIDs.count)
              totalSpawned: \(hordeTotalSpawned)
              lineup: \(lineup.map { $0.rawValue }.joined(separator: ", "))
              noResetToWaveOne: true
            """
        )

        validateWaveSpawnCount(
            expected: successfulSpawnCount
        )

        checkWaveCanEnd(
            wave: nextWave
        )
    }

    private func createLoadedHordeEnemyController(
        id: UUID,
        archetype: PlagueCharacterArchetype,
        position: SIMD3<Float>,
        wave: Int,
        spawnIndex: Int,
        hitsToKill: Int,
        playerHeadPosition: SIMD3<Float>
    ) async throws -> JockRetargetTestController {
        try await createLoadedHordeEnemyController(
            id: id,
            archetype: archetype,
            position: position,
            wave: wave,
            spawnIndex: spawnIndex,
            hitsToKill: hitsToKill,
            playerHeadPosition: playerHeadPosition,
            wireCallbacks: true
        )
    }

    private func createLoadedHordeEnemyController(
        id: UUID,
        archetype: PlagueCharacterArchetype,
        position: SIMD3<Float>,
        wave: Int,
        spawnIndex: Int,
        hitsToKill: Int,
        playerHeadPosition: SIMD3<Float>,
        wireCallbacks: Bool
    ) async throws -> JockRetargetTestController {
        guard hordePortalSystemReady else {
            print(
                """
                [Horde] blocked early character entity load
                  phase: \(hordeRuntimePhase.rawValue)
                  reason: wait_for_first_portal
                """
            )

            throw NSError(
                domain: "HordeSpawn",
                code: 412,
                userInfo: [
                    NSLocalizedDescriptionKey: "Blocked character load before first portal."
                ]
            )
        }

        let attributes = try CharacterAttributeStore.shared.attributes(
            for: archetype
        )

        let prewarmCheckoutStart = TimingProfiler.now()
        let prewarmedAssets = try await hordePrewarmCoordinator.checkoutPreparedAssetsForSpawn(
            characterID: attributes.characterID
        )
        timingProfiler.record(
            "HordeSpawn.checkoutPrewarmedCharacter",
            startTime: prewarmCheckoutStart
        )

        let controller = JockRetargetTestController()

        controller.configureHordeIdentity(
            id: id,
            archetype: archetype,
            wave: wave,
            spawnIndex: spawnIndex,
            hitsToKill: hitsToKill,
            attributes: attributes
        )

        if wireCallbacks {
            wireJockCallbacks(
                controller,
                hostAudioSourceID: id
            )
        }

        controller.installHordePrewarmedAssets(
            characterEntity: prewarmedAssets.characterEntity
        )

        do {
            try await controller.loadIfNeeded()
        } catch {
            hordePrewarmCoordinator.returnCharacterEntityAfterCleanup(
                prewarmedAssets.characterEntity,
                characterID: attributes.characterID,
                reason: "controller_load_failed"
            )

            throw error
        }

        do {
            try controller.prepareFreshHordeSpawn(
                enemyID: id,
                spawnIndex: spawnIndex,
                hitsToKill: hitsToKill,
                initialLifecycle: .portalIngress
            )
        } catch {
            hordePrewarmCoordinator.returnCharacterEntityAfterCleanup(
                prewarmedAssets.characterEntity,
                characterID: attributes.characterID,
                reason: "fresh_spawn_rest_pose_failed"
            )

            throw error
        }

        #if DEBUG
        controller.assertNotInDeathStateAfterFreshSpawn()
        #endif

        controller.configureHordeSpawn(
            position: position,
            playerHeadPosition: playerHeadPosition
        )

        controller.rootEntity.isEnabled = false
        controller.rootEntity.removeFromParent()
        controller.setCombatEnabled(false)
        controller.setRootMotionEnabled(false)
        controller.setExternalMotionDriven(true)

        print(
            """
            [Horde] enemy controller loaded hidden
              enemyID: \(id)
              archetype: \(archetype.rawValue)
              parent: nil
              rootEnabled: false
              reason: ingress_not_ready
            """
        )

        return controller
    }

    private func registerAndRevealHordeEnemy(
        controller: JockRetargetTestController,
        id: UUID,
        archetype: PlagueCharacterArchetype,
        wave: Int,
        spawnIndex: Int,
        currentHeadPosition: SIMD3<Float>
    ) throws {
        guard let sceneRoot else {
            throw NSError(
                domain: "HordeSpawn",
                code: 500,
                userInfo: [
                    NSLocalizedDescriptionKey: "Missing scene root while registering horde enemy"
                ]
            )
        }

        precondition(controller.rootEntity.isEnabled == false)

        hordeEnemyControllersByID[id] = controller
        activeHordeEnemyIDs.insert(id)

        if controller.rootEntity.parent == nil {
            sceneRoot.addChild(controller.rootEntity)
        }

        forestEnvironmentController.applyIBLReceiverRecursively(
            root: controller.rootEntity
        )

        let audioStartDelay = TimeInterval.random(in: 0...1)
        audioController.attachHostAudioSource(
            id: id,
            hostRootEntity: controller.rootEntity,
            archetype: archetype,
            headAudioEntity: controller.characterAudioEmitter,
            breathingStartDelay: audioStartDelay
        )

        do {
            try controller.playFollowDemo(
                resetBenchmarkState: false
            )

            controller.update(
                deltaTime: 1.0 / 60.0,
                currentHeadPosition: currentHeadPosition
            )
        } catch {
            activeHordeEnemyIDs.remove(id)
            hordeEnemyControllersByID.removeValue(forKey: id)
            audioController.stopHostAudioSource(id: id)
            controller.hide()
            controller.rootEntity.removeFromParent()
            recycleHordePrewarmedAssets(
                from: controller
            )
            throw error
        }

        print(
            """
            [Horde] registered/revealed enemy
              wave: \(wave)
              index: \(spawnIndex)
              archetype: \(archetype.rawValue)
              id: \(id)
              rootEnabled: \(controller.rootEntity.isEnabled)
              hasParent: \(controller.rootEntity.parent != nil)
              audioStartDelay: \(String(format: "%.3f", audioStartDelay))
              entityName: \(controller.rootEntity.name)
              entityObject: \(Unmanaged.passUnretained(controller.rootEntity).toOpaque())
              registeredBeforeVisible: true
              playFollowDemoAfterRegister: true
              primedOneTick: true
            """
        )
    }

    private func registerHordeEnemyForInstancedPortalIngress(
        controller: JockRetargetTestController,
        id: UUID,
        archetype: PlagueCharacterArchetype,
        wave: Int,
        spawnIndex: Int,
        portal: HordePortal,
        side: HordePortalEntranceSide,
        assignmentKind: HordePortalAssignment.AssignmentKind,
        currentHeadPosition: SIMD3<Float>
    ) throws {
        guard let sceneRoot else {
            throw NSError(
                domain: "HordeSpawn",
                code: 500,
                userInfo: [
                    NSLocalizedDescriptionKey: "Missing scene root while registering portal horde enemy"
                ]
            )
        }

        precondition(controller.rootEntity.isEnabled == false)

        hordeEnemyControllersByID[id] = controller
        activeHordeEnemyIDs.insert(id)

        forestEnvironmentController.applyIBLReceiverRecursively(
            root: controller.rootEntity
        )

        do {
            let ingress = try HordePortalInstancedIngressController(
                enemy: controller,
                portal: portal,
                sceneRoot: sceneRoot,
                side: side
            )

            activeIngressControllers[id] = ingress

            controller.update(
                deltaTime: 1.0 / 60.0,
                currentHeadPosition: currentHeadPosition
            )
        } catch {
            activeHordeEnemyIDs.remove(id)
            hordeEnemyControllersByID.removeValue(forKey: id)
            controller.hide()
            controller.rootEntity.removeFromParent()
            recycleHordePrewarmedAssets(
                from: controller
            )
            throw error
        }

        print(
            """
            [HordePortalIngress] enemy revealed through portal
              enemyID: \(id)
              rootEnabled: \(controller.rootEntity.isEnabled)
              firstPosePrimed: true
              noPrePortalAPose: true
              portalRenderInstance: true
              breathingAudioStartsAtRoomReveal: true
            """
        )

        print(
            """
            [HordePortal] portal-world ingress assigned
              wave: \(wave)
              index: \(spawnIndex)
              enemyID: \(id)
              archetype: \(archetype.rawValue)
              portalID: \(portal.id)
              assignmentKind: \(assignmentKind.rawValue)
              side: \(side.rawValue)
              breathingAudioStart: room_visual_reveal
              realParent: sceneRoot
              portalVisual: render_instance
              secondController: false
              secondAnimationClock: false
              noOpacityFade: true
            """
        )
    }

    private func handleHordeSpawnFailure(
        _ record: HordeSpawnFailureRecord
    ) {
        hordeSpawnFailures.append(record)
        hordeWaveSpawnState = activeHordeEnemyIDs.isEmpty ? .failed : .degraded

        print(
            """
            [Horde] spawn failure recorded
              wave: \(record.wave)
              index: \(record.spawnIndex)
              archetype: \(record.archetype.rawValue)
              reason: \(record.reason)
              state: \(hordeWaveSpawnState.rawValue)
              activeEnemiesPreserved: \(activeHordeEnemyIDs.count)
              noResetToWaveOne: true
            """
        )
    }

    private func hordeSpawnPositions(
        count: Int,
        spawnPose: PhaseOneSpawnPose,
        floorY: Float
    ) -> [SIMD3<Float>] {
        guard count > 0 else { return [] }

        let front = PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(
                spawnPose.headForward.x,
                0,
                spawnPose.headForward.z
            ),
            fallback: SIMD3<Float>(0, 0, -1)
        )

        let right = PhaseOneMath.normalizedOrFallback(
            simd_cross(front, SIMD3<Float>(0, 1, 0)),
            fallback: SIMD3<Float>(1, 0, 0)
        )

        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(count)

        let candidateCount = max(count * 8, 16)

        for index in 0..<candidateCount {
            guard positions.count < count else {
                break
            }

            let angle = Float(index) * 2.0 * .pi / Float(candidateCount)
            let direction = PhaseOneMath.normalizedOrFallback(
                front * cos(angle) + right * sin(angle),
                fallback: front
            )

            let candidate = SIMD3<Float>(
                spawnPose.headPosition.x + direction.x * hordeSpawnRadiusMeters,
                floorY,
                spawnPose.headPosition.z + direction.z * hordeSpawnRadiusMeters
            )

            if roomSkinningCoordinator.isUnsafeCombatPositionNearConfirmedPortalWall(candidate) {
                print("[RoomSkinning] rejected combat spawn near portal wall")
                continue
            }

            positions.append(candidate)
        }

        return positions
    }

    private func validateWaveSpawnCount(
        expected: Int
    ) {
        let activeIDCount = activeHordeEnemyIDs.count
        let activeControllerCount = hordeEnemyControllersByID.count

        print(
            """
            [HordeBenchmark] wave spawn validation
              wave: \(hordeCurrentWave)
              expected: \(expected)
              activeEnemyIDs: \(activeIDCount)
              activeControllers: \(activeControllerCount)
              aliveEnemies: \(activeIDCount)
            """
        )

        if activeIDCount != expected ||
            activeControllerCount != expected {
            print(
                """
                [HordeBenchmark] ERROR wave spawned wrong count
                  expected: \(expected)
                  activeEnemyIDs: \(activeIDCount)
                  activeControllers: \(activeControllerCount)
                """
            )
        }
    }

    private func clearHordeEnemyControllers() {
        for (id, controller) in hordeEnemyControllersByID {
            audioController.stopHostAudioSource(id: id)
            controller.forceCleanupFromHordeScene(
                reason: "clear_live_horde_enemy_controllers"
            )
            recycleHordePrewarmedAssets(
                from: controller
            )
        }

        hordeEnemyControllersByID.removeAll()
        activeHordeEnemyIDs.removeAll()

        cleanupHordeCorpsesForWaveTransition(
            reason: "clear_horde_enemy_controllers"
        )
    }

    private func recycleHordePrewarmedAssets(
        from controller: JockRetargetTestController
    ) {
        guard controller.hordeLifecycleState == .cleanedUp else {
            print(
                """
                [HordeLifecycle] ERROR attempted to discard clone before cleanup
                  enemyID: \(controller.hordeBenchmarkID.uuidString)
                  lifecycle: \(controller.hordeLifecycleState.rawValue)
                """
            )

            return
        }

        guard let reusable = controller.detachHordePrewarmedCharacterEntityForReuse() else {
            return
        }

        hordePrewarmCoordinator.returnCharacterEntityAfterCleanup(
            reusable.entity,
            characterID: reusable.characterID,
            reason: "horde_controller_cleanup"
        )

        print(
            """
            [HordeLifecycle] dirty gameplay clone discarded after cleanup
              enemyID: \(controller.hordeBenchmarkID.uuidString)
              characterID: \(reusable.characterID)
              returnedToPool: false
            """
        )
    }

    @discardableResult
    private func registerConfirmedHordePlayerHit(
        amount: Int,
        attackerID: UUID?
    ) -> Bool {
        guard hordeBenchmarkRunning else { return false }
        guard !isPlayerDeathSequenceActive else { return true }

        hordePlayerHitsThisWave += 1

        print(
            """
            [HordeBenchmark] confirmed player hit
              wave: \(hordeCurrentWave)
              hitsThisWave: \(hordePlayerHitsThisWave)
              limit: \(hordePlayerHitLimitPerWave)
              amount: \(amount)
              attackerID: \(attackerID?.uuidString ?? "nil")
            """
        )

        guard hordePlayerHitsThisWave >= hordePlayerHitLimitPerWave else {
            return false
        }

        handleHordeBenchmarkPlayerDeath(
            wave: hordeCurrentWave,
            hitsThisWave: hordePlayerHitsThisWave
        )

        return true
    }

    private func handleHordeBenchmarkPlayerDeath(
        wave: Int,
        hitsThisWave: Int
    ) {
        guard !isPlayerDeathSequenceActive else { return }

        isPlayerDeathSequenceActive = true
        hordeRuntimePhase = .playerDead
        submitHordeScoresIfNeeded(
            reason: "player_death"
        )
        pendingNextBenchmarkWaveTask?.cancel()
        pendingNextBenchmarkWaveTask = nil
        jockRetargetController?.setPlayerAttackEnabled(false)

        for controller in hordeEnemyControllersByID.values {
            controller.setBenchmarkPlayerDead(true)
            controller.setPlayerAttackEnabled(false)
        }

        print(
            """
            [HordeBenchmark] Handling player death
              wave: \(wave)
              hitsThisWave: \(hitsThisWave)
            """
        )

        let deathAudioDuration = audioController.playRandomPlayerDeathAndReturnDuration()
        onPlayerDeathStarted?()
        showInstructionHUD(
            "You died. The breach remains."
        )

        deathPresentationController?.playDeathBlackoutSequence { [weak self] in
            guard let self else { return }

            self.clearHordeEnemiesAfterDeathBlackout()

            if let sceneRoot = self.sceneRoot,
               let headAnchor = self.headAnchor {
                self.playYouDiedRoomAnchored(
                    world: sceneRoot,
                    head: headAnchor
                )
            } else {
                print("[PlagueDeath] Cannot show you_died.png; missing world or head anchor.")
            }

            print("[PlagueDeath] final dark reached; horde cleared; you_died shown after cleanup.")
        }

        Task { @MainActor in
            let delay = deathAudioDuration + 3.0

            try? await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )

            guard isPlayerDeathSequenceActive else { return }

            deathPresentationController?.fadeBackUp(duration: 1.25)
            await fadeYouDiedAlpha(
                to: 0.0,
                duration: 0.30
            )
            cleanupYouDied()

            print("[PlagueDeath] lights coming back up.")
        }
    }

    private func resetHordeBenchmarkDeathPresentation() {
        pendingNextBenchmarkWaveTask?.cancel()
        pendingNextBenchmarkWaveTask = nil
        isPlayerDeathSequenceActive = false
        jockRetargetController?.setPlayerAttackEnabled(true)
        deathPresentationController?.reset()
        cleanupYouDied()
    }

    private func clearHordeEnemiesAfterDeathBlackout() {
        for (id, controller) in hordeEnemyControllersByID {
            audioController.stopHostAudioSource(id: id)
            controller.stopForBenchmarkPlayerDeath()
            controller.forceCleanupFromHordeScene(
                reason: "player_death"
            )
            recycleHordePrewarmedAssets(
                from: controller
            )
        }

        hordeEnemyControllersByID.removeAll()
        activeHordeEnemyIDs.removeAll()
        cleanupHordeCorpsesForWaveTransition(
            reason: "player_death"
        )
        resetHordeSimulationPipeline()
        hordeBenchmarkRunning = false
        hordeRuntimePhase = .playerDead
        audioController.stopHordeMusicSequence()
        audioController.stopDemoAudio()

        print(
            """
            [PlagueDeath] preserved room skinning after death
              SwiftUISuppressed: true
              wallPosterUIActive: true
              portalCount: \(hordePortalManager.portals.count)
            """
        )

        print("[PlagueDeath] active enemies and corpses cleared after final dark; death billboard preserved.")
    }

    private func handleBenchmarkEnemyKilled(
        id: UUID,
        wave: Int
    ) {
        guard !isPlayerDeathSequenceActive else {
            print("[HordeBenchmark] enemyKilled ignored: player death active")
            return
        }

        guard activeHordeEnemyIDs.contains(id),
              let controller = hordeEnemyControllersByID.removeValue(
                forKey: id
              ) else {
            print(
                """
                [HordeBenchmark] WARNING enemyKilled id not active
                  id: \(id)
                  activeIDsCount: \(activeHordeEnemyIDs.count)
                  activeIDs: \(activeHordeEnemyIDs.map { $0.uuidString }.joined(separator: ", "))
                """
            )
            return
        }

        activeHordeEnemyIDs.remove(id)
        dyingHordeEnemyIDs.insert(id)
        hordeDyingEnemyControllersByID[id] = controller
        activeIngressControllers.removeValue(forKey: id)
        controller.didStartDeathLifecycle = true
        controller.disableHordeSystemsForDeath()
        audioController.stopCharacterLoopAudio(id: id)

        print(
            """
            [HordeLifecycle] enemy moved active -> dying
              enemyID: \(id)
              characterID: \(controller.enemySeparationCharacterID)
              removedFromActiveMap: true
              collisionDisabled: true
              followDisabled: true
            """
        )

        hordeTotalKilled += 1

        print(
            """
            [HordeBenchmark] kill shot confirmed
              id: \(id)
              wave: \(wave)
              aliveRemaining: \(activeHordeEnemyIDs.count)
              active: \(activeHordeEnemyIDs.count)
              dying: \(dyingHordeEnemyIDs.count)
              corpses: \(corpseHordeEnemyIDs.count)
              waveState: \(hordeWaveSpawnState.rawValue)
              totalKilled: \(hordeTotalKilled)
              removedFromActiveMap: true
            """
        )

        assertNoCorpseInActiveEnemyMap()

        checkWaveCanEnd(
            wave: wave
        )
    }

    private func handleBenchmarkEnemyDeathAnimationFinished(
        id: UUID,
        wave: Int
    ) {
        if let controller = hordeDyingEnemyControllersByID.removeValue(
            forKey: id
        ) {
            dyingHordeEnemyIDs.remove(id)
            corpseHordeEnemyIDs.insert(id)
            controller.freezeAsHordeCorpse()

            hordeCorpseRecordsByID[id] = HordeCorpseRecord(
                enemyID: id,
                characterID: controller.enemySeparationCharacterID,
                rootEntity: controller.rootEntity,
                controller: controller,
                deathTime: Date().timeIntervalSinceReferenceDate
            )

            print(
                """
                [HordeLifecycle] dying -> corpse record
                  enemyID: \(id)
                  characterID: \(controller.enemySeparationCharacterID)
                  corpseCount: \(hordeCorpseRecordsByID.count)
                """
            )
        } else if !corpseHordeEnemyIDs.contains(id) {
            print(
                """
                [HordeBenchmark] WARNING death animation finished for unknown id
                  id: \(id)
                  active: \(activeHordeEnemyIDs.count)
                  dying: \(dyingHordeEnemyIDs.count)
                  corpses: \(corpseHordeEnemyIDs.count)
                """
            )
            corpseHordeEnemyIDs.insert(id)
        }

        print(
            """
            [HordeBenchmark] corpse registered
              id: \(id)
              wave: \(wave)
              active: \(activeHordeEnemyIDs.count)
              dying: \(dyingHordeEnemyIDs.count)
              corpses: \(corpseHordeEnemyIDs.count)
              waveState: \(hordeWaveSpawnState.rawValue)
            """
        )

        checkWaveCanEnd(
            wave: wave
        )
    }

    private func checkWaveCanEnd(
        wave: Int
    ) {
        guard hordeBenchmarkRunning else { return }
        guard !isPlayerDeathSequenceActive else { return }
        guard pendingNextBenchmarkWaveTask == nil else {
            print("[HordeBenchmark] wave clear ignored: next wave already pending")
            return
        }

        guard activeHordeEnemyIDs.isEmpty,
              dyingHordeEnemyIDs.isEmpty else {
            print(
                """
                [HordeBenchmark] wave not clear yet
                  wave: \(wave)
                  active: \(activeHordeEnemyIDs.count)
                  dying: \(dyingHordeEnemyIDs.count)
                  corpses: \(corpseHordeEnemyIDs.count)
                  waveState: \(hordeWaveSpawnState.rawValue)
                """
            )
            return
        }

        guard hordeWaveSpawnState == .active ||
            hordeWaveSpawnState == .degraded else {
            print(
                """
                [HordeBenchmark] wave clear ignored in state
                  wave: \(wave)
                  state: \(hordeWaveSpawnState.rawValue)
                  active: \(activeHordeEnemyIDs.count)
                  dying: \(dyingHordeEnemyIDs.count)
                  corpses: \(corpseHordeEnemyIDs.count)
                """
            )
            return
        }

        print(
            """
            [HordeBenchmark] wave cleared
              wave: \(wave)
              state: \(hordeWaveSpawnState.rawValue)
              spawnFailures: \(hordeSpawnFailures.count)
              corpsesToClear: \(corpseHordeEnemyIDs.count)
              nextWave: \(wave + 1)
            """
        )

        onHordeWaveCleared?(
            wave
        )

        pendingNextBenchmarkWaveTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(benchmarkNextWaveDelaySeconds * 1_000_000_000)
            )

            pendingNextBenchmarkWaveTask = nil

            guard hordeBenchmarkRunning,
                  !isPlayerDeathSequenceActive else { return }

            clearWaveCorpses()

            await spawnNextHordeWave()
        }
    }

    private func clearWaveCorpses() {
        cleanupHordeCorpsesForWaveTransition(
            reason: "wave_transition"
        )
    }

    private func cleanupHordeCorpsesForWaveTransition(
        reason: String
    ) {
        guard !hordeCorpseRecordsByID.isEmpty ||
            !hordeDyingEnemyControllersByID.isEmpty ||
            !corpseHordeEnemyIDs.isEmpty ||
            !dyingHordeEnemyIDs.isEmpty else {
            return
        }

        print(
            """
            [HordeLifecycle] corpse cleanup starting
              reason: \(reason)
              corpseCount: \(hordeCorpseRecordsByID.count)
              dyingCount: \(hordeDyingEnemyControllersByID.count)
            """
        )

        for (enemyID, controller) in hordeDyingEnemyControllersByID {
            audioController.stopHostAudioSource(id: enemyID)
            activeIngressControllers.removeValue(forKey: enemyID)
            controller.forceCleanupFromHordeScene(
                reason: reason
            )
            recycleHordePrewarmedAssets(
                from: controller
            )
        }

        hordeDyingEnemyControllersByID.removeAll()
        dyingHordeEnemyIDs.removeAll()

        for (enemyID, record) in hordeCorpseRecordsByID {
            audioController.stopHostAudioSource(id: enemyID)
            activeIngressControllers.removeValue(forKey: enemyID)
            record.controller.forceCleanupFromHordeScene(
                reason: reason
            )
            recycleHordePrewarmedAssets(
                from: record.controller
            )
        }

        hordeCorpseRecordsByID.removeAll()
        corpseHordeEnemyIDs.removeAll()

        print(
            """
            [HordeLifecycle] corpse cleanup complete
              reason: \(reason)
              corpseCount: \(hordeCorpseRecordsByID.count)
              dyingCount: \(hordeDyingEnemyControllersByID.count)
            """
        )
    }

    private func assertNoCorpseInActiveEnemyMap() {
        for (id, controller) in hordeEnemyControllersByID {
            if !controller.hordeLifecycleState.isLivingGameplayEnemy {
                assertionFailure(
                    """
                    [HordeLifecycle] corpse/dying/cleaned enemy in active map
                      enemyID: \(id)
                      lifecycle: \(controller.hordeLifecycleState.rawValue)
                    """
                )
            }
        }
    }

    private func playYouDiedRoomAnchored(
        world: AnchorEntity,
        head: AnchorEntity
    ) {
        guard !youDiedRunning else {
            print("[PlagueDeath] you_died already running.")
            return
        }

        cleanupYouDied()
        youDiedRunning = true

        let headMatrix = head.transformMatrix(relativeTo: world)
        let headPosition = head.position(relativeTo: world)

        var forward = -SIMD3<Float>(
            headMatrix.columns.2.x,
            headMatrix.columns.2.y,
            headMatrix.columns.2.z
        )

        if simd_length(forward) < 0.0001 {
            forward = SIMD3<Float>(0, 0, -1)
        } else {
            forward = simd_normalize(forward)
        }

        let targetPosition = headPosition +
            forward * YOU_DIED_FORWARD_M +
            SIMD3<Float>(0, YOU_DIED_Y_OFFSET_M, 0)

        let rig = Entity()
        rig.name = "YouDiedRig"
        rig.position = targetPosition

        let directionToHead = PhaseOneMath.normalizedOrFallback(
            headPosition - targetPosition,
            fallback: SIMD3<Float>(0, 0, 1)
        )
        let upWorld = SIMD3<Float>(0, 1, 0)
        var right = simd_cross(upWorld, directionToHead)
        if simd_length_squared(right) < 1e-6 {
            right = SIMD3<Float>(1, 0, 0)
        }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(directionToHead, right))
        let rotation = simd_float3x3(
            columns: (
                right,
                up,
                directionToHead
            )
        )
        rig.orientation = simd_quatf(rotation)

        guard let texture = loadYouDiedTexture() else {
            print("[PlagueDeath] ERROR: could not load you_died.png")
            youDiedRunning = false
            return
        }

        let material = makeYouDiedMaterialFromDarkMatterPattern(
            texture: texture,
            alpha: 0.0
        )

        let imageSize = loadYouDiedImageSize()
        let aspect = max(
            0.01,
            (imageSize?.width ?? 1672) / max(1, imageSize?.height ?? 941)
        )
        let heightMeters = YOU_DIED_HEIGHT_M
        let widthMeters = min(
            YOU_DIED_WIDTH_M,
            heightMeters * Float(aspect)
        )

        let imageEntity = ModelEntity(
            mesh: .generatePlane(
                width: widthMeters,
                height: heightMeters
            ),
            materials: [material]
        )

        imageEntity.name = "you_died.png"
        imageEntity.position = .zero

        rig.addChild(imageEntity)
        world.addChild(rig)

        youDiedRig = rig
        youDiedLogo = imageEntity
        youDiedAlpha = 0.0

        print(
            """
            [PlagueDeath] you_died room anchored
              world: \(world.name)
              head: \(head.name)
              rigParent: \(rig.parent?.name ?? "nil")
              logoParent: \(imageEntity.parent?.name ?? "nil")
              headPosition: \(headPosition)
              rigPosition: \(targetPosition)
              forward: \(forward)
              distanceFromHead: \(simd_length(targetPosition - headPosition))
              width: \(widthMeters)
              height: \(heightMeters)
            """
        )

        dumpYouDiedDiagnostic()

        Task { @MainActor in
            await fadeYouDiedAlpha(
                to: 1.0,
                duration: 0.20
            )
        }
    }

    private func validateDeathPresentationAssets() {
        if Bundle.main.url(
            forResource: "you_died",
            withExtension: "png"
        ) == nil {
            print("[PlagueDeath] WARNING you_died.png not found in main bundle")
        }
    }

    private func loadYouDiedTexture() -> TextureResource? {
        if let url = Bundle.main.url(
            forResource: "you_died",
            withExtension: "png"
        ) {
            print("[PlagueDeath] found you_died.png in bundle: \(url.path)")
        } else {
            print("[PlagueDeath] WARNING: Bundle.main cannot find you_died.png")
        }

        if let texture = try? TextureResource.load(named: "you_died") {
            print("[PlagueDeath] loaded TextureResource named you_died")
            return texture
        }

        if let texture = try? TextureResource.load(named: "you_died.png") {
            print("[PlagueDeath] loaded TextureResource named you_died.png")
            return texture
        }

        print("[PlagueDeath] ERROR: TextureResource.load failed for you_died and you_died.png")
        return nil
    }

    private func loadYouDiedImageSize() -> CGSize? {
        if let image = UIImage(named: "you_died") {
            return image.size
        }

        guard let url = Bundle.main.url(
            forResource: "you_died",
            withExtension: "png"
        ),
              let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }

        return image.size
    }

    private func makeYouDiedMaterialFromDarkMatterPattern(
        texture: TextureResource,
        alpha: Float
    ) -> UnlitMaterial {
        let alpha = max(0, min(1, alpha))

        var material = UnlitMaterial()
        material.color = .init(
            tint: UIColor.white.withAlphaComponent(CGFloat(alpha)),
            texture: .init(texture)
        )
        material.blending = .transparent(opacity: .init(floatLiteral: max(0.001, alpha)))

        return material
    }

    private func setYouDiedAlpha(
        _ alpha: Float
    ) {
        youDiedAlpha = max(0, min(1, alpha))

        guard let logo = youDiedLogo,
              var material = logo.model?.materials.first as? UnlitMaterial else {
            print("[PlagueDeath] setYouDiedAlpha ignored: no logo material")
            return
        }

        let texture = material.color.texture

        material.color = .init(
            tint: UIColor.white.withAlphaComponent(CGFloat(youDiedAlpha)),
            texture: texture
        )
        material.blending = .transparent(opacity: .init(floatLiteral: max(0.001, youDiedAlpha)))

        logo.model?.materials = [material]

        print("[PlagueDeath] you_died alpha set: \(youDiedAlpha)")
    }

    private func fadeYouDiedAlpha(
        to target: Float,
        duration: TimeInterval
    ) async {
        let start = youDiedAlpha
        let startTime = CACurrentMediaTime()

        while !Task.isCancelled {
            let elapsed = CACurrentMediaTime() - startTime
            let progress = min(1.0, elapsed / max(duration, 0.001))
            let eased = Float(progress * progress * (3.0 - 2.0 * progress))
            let value = start + (target - start) * eased

            setYouDiedAlpha(value)

            if progress >= 1.0 {
                break
            }

            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    private func cleanupYouDied() {
        youDiedLogo?.removeFromParent()
        youDiedLogo = nil

        youDiedRig?.removeFromParent()
        youDiedRig = nil

        youDiedAlpha = 0.0
        youDiedRunning = false

        print("[PlagueDeath] you_died cleaned up")
    }

    private func dumpYouDiedDiagnostic() {
        print(
            """
            [PlagueDeath] you_died diagnostic
              youDiedRunning: \(youDiedRunning)
              hasRig: \(youDiedRig != nil)
              hasLogo: \(youDiedLogo != nil)
              rigParent: \(youDiedRig?.parent?.name ?? "nil")
              logoParent: \(youDiedLogo?.parent?.name ?? "nil")
              logoIsEnabled: \(youDiedLogo?.isEnabled ?? false)
              logoPosition: \(youDiedLogo?.position ?? .zero)
              rigPosition: \(youDiedRig?.position ?? .zero)
              alpha: \(youDiedAlpha)
              materialCount: \(youDiedLogo?.model?.materials.count ?? 0)
            """
        )
    }
}
