import Foundation
import Combine
import QuartzCore
import RealityKit
import simd
import UIKit
import TuringQwenNative

@MainActor
final class PlagueImmersiveCoordinator: ObservableObject, TuringStoryStateTeleportWorld {
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

    private enum HordeWaveRules {
        static let maxConcurrentCombatants = 6
        static let replacementCorpseCleanupDelaySeconds: TimeInterval = 4.0

        static func initialLineup(
            wave: Int
        ) -> [PlagueCharacterArchetype] {
            let normalizedWave = max(0, wave)

            if normalizedWave <= maxConcurrentCombatants {
                return HordeCharacterWaveLineup.lineup(
                    wave: normalizedWave
                )
            }

            let baselineSix = HordeCharacterWaveLineup.lineup(
                wave: maxConcurrentCombatants
            )

            assert(
                baselineSix.count == maxConcurrentCombatants,
                "Wave 6 must contain the canonical six-character roster"
            )

            return Array(
                baselineSix.prefix(maxConcurrentCombatants)
            )
        }

        static func replacementBudget(
            wave: Int
        ) -> Int {
            max(
                0,
                wave - maxConcurrentCombatants
            )
        }
    }

    private struct HordeDeathReplacementRequest {
        let runID: UUID
        let waveGeneration: UUID
        let deadEnemyID: UUID
        let replacementEnemyID: UUID
        let wave: Int
        let archetype: PlagueCharacterArchetype
        let replacementSpawnIndex: Int
    }

    private struct HordeWaveDeathReplacementState {
        let runID: UUID
        let generation: UUID
        let wave: Int
        let replacementBudget: Int

        var consumedReplacementCount = 0
        var successfulReplacementCount = 0
        var failedReplacementCount = 0
        var deathIDsThatConsumedToken = Set<UUID>()
        var queuedRequests: [HordeDeathReplacementRequest] = []
        var inFlightRequest: HordeDeathReplacementRequest?
        var reservedReplacementEnemyIDs = Set<UUID>()
        var corpseIDsEligibleForReplacementCleanup = Set<UUID>()

        var hasReplacementRemaining: Bool {
            consumedReplacementCount < replacementBudget
        }

        var pendingReplacementCount: Int {
            reservedReplacementEnemyIDs.count
        }
    }

    private let spatialProvider = PhaseOneSpatialProvider()
    private let audioController = GravitasDemoAudioController()
    private let forestEnvironmentController = PlagueGaussianForestEnvironmentController()
    private let roomSkinningCoordinator = RoomSkinningCoordinator(
        portalRuntimePolicy: .disabledForTuringStory
    )
    private let hordePortalManager = HordePortalManager()
    private let wallPosterUIController = WallMountedPosterUIController()
    private let turingWalkieBundleController = TuringStoryWalkieBundleController()
    private let turingWindowBundleController = TuringStoryWindowBundleController()
    private let turingDoorBundleController = TuringStoryDoorBundleController()
    private let turingRollingBenchBundleController = TuringRollingBenchBundleController()
    private lazy var mindEyePresentationCoordinator =
        MindEyePresentationCoordinator.makeDefault()
    private lazy var mindEyeRuntimeLifecycle =
        MindEyeRuntimeLifecycleCoordinator(
            presentation: mindEyePresentationCoordinator
        )
    private var battle01Coordinator: Battle01Coordinator?
    private var chapter01RobotEncounterCoordinator:
        Chapter01RobotEncounterCoordinator?
    private var chapter01DadWindowCoordinator:
        Chapter01DadWindowCoordinator?
    private var chapter01DadFinalBattleCoordinator:
        Chapter01DadFinalBattleCoordinator?
    private var chapter01Coordinator: Chapter01Coordinator?
    private var chapter02WindowWomanCoordinator:
        Chapter02WindowWomanCoordinator?
    private var chapter02WomanBattleCoordinator:
        Chapter02WomanBattleCoordinator?
    private var chapter02Coordinator: Chapter02Coordinator?
    private var chapter03Coordinator: Chapter03Coordinator?
    private var prologueStoryActionRouter: PrologueStoryActionRouter?
    private var prologueCompletionCoordinator: TuringPrologueCompletionCoordinator?
    private var storyCompletionRouter: TuringStoryCompletionRouter?
    private let storyTitleCardTransitionCoordinator =
        StoryTitleCardTransitionCoordinator()
    private let cinematicWorldPresentationCoordinator =
        CinematicWorldPresentationCoordinator()
    private let storyAmbientGunfireWorldBridge =
        StoryAmbientGunfireWorldBridge()
    private var storyAmbientGunfireLifecycle:
        StoryAmbientGunfireLifecycleController?
    private let storyAmbientCountyWorldBridge =
        StoryAmbientGunfireWorldBridge(channel: .county)
    private var storyAmbientCountyLifecycle:
        StoryAmbientGunfireLifecycleController?
    private let storyAmbientCountySecondaryWorldBridge =
        StoryAmbientGunfireWorldBridge(channel: .countySecondary)
    private var storyAmbientCountySecondaryLifecycle:
        StoryAmbientGunfireLifecycleController?
    private let storyAmbientAircraftWorldBridge =
        StoryAmbientAircraftWorldBridge()
    private var storyAmbientAircraftLifecycle:
        StoryAmbientAircraftLifecycleController?
    private var turingHighMemoryPreflightAdapter:
        StoryTuringHighMemoryPreflightAdapter?
    private let wallPropOccupancyRegistry = WallPropOccupancyRegistry()
    private lazy var turingStoryPlacementAdjustmentCoordinator =
        TuringStoryPlacementAdjustmentCoordinator(
            wallProvider: roomSkinningCoordinator.wallManager,
            frontEdgeProvider: turingRollingBenchBundleController,
            adapters: [
                .door: turingDoorBundleController,
                .rollingBench: turingRollingBenchBundleController,
                .window: turingWindowBundleController,
                .walkieShelf: turingWalkieBundleController,
                .poster: wallPosterUIController
            ]
        )
    private lazy var turingStoryWallLayoutCoordinator = TuringStoryWallLayoutCoordinator(
        doorController: turingDoorBundleController,
        rollingBenchController: turingRollingBenchBundleController,
        windowController: turingWindowBundleController,
        walkieController: turingWalkieBundleController,
        posterController: wallPosterUIController,
        onCommitted: { [weak self] scanID, adjustmentSeed in
            guard let self else { return }
            self.turingStoryPlacementAdjustmentCoordinator.activate(
                seed: adjustmentSeed
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard MindEyeQualificationFeatureControl.isMindEyeEnabled else {
                    return
                }
                await self.mindEyePresentationCoordinator.arm(
                    characterID: .bigMike,
                    reason: "storyLayoutCommitted.\(scanID)"
                )
            }
            self.configureTuringWalkieAudioAndInteraction(
                reason: "sliceLayout.\(scanID)",
                attempt: 1
            )
            self.forestEnvironmentController.applyIBLReceiverRecursively(
                root: self.wallPosterUIController.root
            )
            self.onWallPosterUIActiveChanged?(true)
            self.turingHUDDelayedClearTask?.cancel()
            self.turingHUDDelayedClearTask = nil
            self.instructionHUD.clear()
            print("[TuringWallSlices] placement HUD cleared scanID=\(scanID)")
            self.storyAmbientGunfireLifecycle?.storyPropsDidCommit(
                reason: "sliceLayout.\(scanID)"
            )
            self.storyAmbientCountyLifecycle?.storyPropsDidCommit(
                reason: "sliceLayout.\(scanID)"
            )
            self.storyAmbientCountySecondaryLifecycle?.storyPropsDidCommit(
                reason: "sliceLayout.\(scanID)"
            )
            self.storyAmbientAircraftLifecycle?.storyPropsDidCommit(
                reason: "sliceLayout.\(scanID)"
            )
            self.onTuringStoryStagePlacementCommitted?("sliceLayout.\(scanID)")
            self.finishTuringDebugRescanIfNeeded(
                scanID: scanID,
                outcome: "committed"
            )
            self.startPendingTuringDebugRescanIfNeeded(
                trigger: "layoutCommitted.\(scanID)"
            )
        },
        onFailed: { [weak self] scanID, error in
            self?.turingStoryPlacementAdjustmentCoordinator.cancel(
                reason: "initialLayoutFailed.\(scanID)"
            )
            self?.showTemporaryInstructionHUD(
                "Prop placement failure. Scan again to retry.",
                clearAfterSeconds: 5.0,
                reason: "sliceLayoutFailed.\(scanID)"
            )
            print("[TuringWallSlices] placement failure surfaced scanID=\(scanID) error=\(error)")
            self?.onTuringStoryStagePlacementFailed?(
                NSError(
                    domain: "TuringStoryStage",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: error]
                ),
                "sliceLayout.\(scanID)"
            )
            self?.finishTuringDebugRescanIfNeeded(
                scanID: scanID,
                outcome: "failed.\(error)"
            )
            self?.startPendingTuringDebugRescanIfNeeded(
                trigger: "layoutFailed.\(scanID)"
            )
        }
    )
    private let hordeRoomScanTracker = HordeRoomScanTracker()
    private let turingPlacementRoomScanTracker = HordeRoomScanTracker()
    private let turingStoryScanSpinTracker = TuringStoryScanSpinTracker()
    private let enemyBodySeparationResolver = HordeEnemyBodySeparationResolver()
    private let instructionHUD = PlagueHeadTrackedInstructionHUD()
    private var turingHUDDelayedClearTask: Task<Void, Never>?
    private let turingQuestionReminderDurationSeconds: TimeInterval = 7.0
    private let timingProfiler = TimingProfiler(label: "main_actor_shell")
    private let hordeSimulationEngine = HordeSimulationEngine()
    private let hordeEnemyBrainEngine = HordeEnemyBrainEngine()
    private let hordePrewarmCoordinator = HordePrewarmCoordinator()
    private let turingStoryWalkieInteractionController =
        TuringStoryWalkieInteractionController()
    private let turingStoryDadFrameInteractionController =
        TuringStoryDadFrameInteractionController()
    private var turingWaitingForPlacementRoomScan = false
    private var turingWaitingForPlacementFloorPromptShown = false
    private var turingStoryPlacementScanCompleted = false
    private var turingStoryPlacementSpinResult: TuringStoryScanSpinResult?
    private var pendingTuringPlacementScanReasons: [String] = []
    private var turingDebugRescanAttempt = 0
    private var activeTuringDebugRescanAttempt: Int?
    private var pendingTuringDebugRescanReason: String?

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
    private var lastHordeBrainSubmitTime: TimeInterval = 0
    private var forceNextHordeBrainSubmit = false

    @Published private(set) var isPlayerDeathSequenceActive = false

    var onPlayerDamaged: ((Int) -> Void)?
    var onPlayerDeathStarted: (() -> Void)?
    var onStoryEpisodePickerRequested: ((String) -> Void)?
    var onOperationMenuRequested: ((String) -> Void)?
    @MainActor
    var onYouDiedWorldCardRequested: ((simd_float4x4) -> Void)?

    @MainActor
    var onYouDiedWorldCardCleanupRequested: (() -> Void)?

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
    var onTuringStoryStagePlacementCommitted: ((String) -> Void)?
    var onTuringStoryStagePlacementFailed: ((Error, String) -> Void)?
    var onStoryModeSwitchRuntimeTornDown: ((String) -> Void)?
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
    private var currentHordeRunID = UUID()
    private var hordeWaveSpawnState: HordeWaveSpawnState = .idle
    private var hordeSpawnFailures: [HordeSpawnFailureRecord] = []
    private var isSpawningHordeWave = false
    private var hordePrewarmReady = false
    private var hordePrewarmTask: Task<Bool, Never>?
    private var hordeScoresSubmittedForCurrentRun = false
    private var hordeWaitingForRoomScan = false
    private var hordeWaitingForFloorPromptShown = false
    private var hordeRoomScanCompletionTask: Task<Void, Never>?
    private var operationModeSwitchTask: Task<Void, Never>?
    private var operationModeSwitchGeneration = 0
    private var activeIngressControllers: [UUID: HordePortalInstancedIngressController] = [:]
    private var retainedPortalMirrorControllersByEnemyID: [UUID: HordePortalInstancedIngressController] = [:]
    private var hordeDeathReplacementState: HordeWaveDeathReplacementState?
    private var hordeReplacementPumpTask: Task<Void, Never>?
    private var hordeReplacementPumpID: UUID?
    private var hordeReplacementCorpseCleanupTasksByEnemyID: [UUID: Task<Void, Never>] = [:]
    private var lastWallPosterPlacementAttempt: Date?
    private var currentStoryWindowAtmosphere: PortalHDRIAtmosphere = .night

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

    func configureStoryTitleCardPresentation(
        presenter: StoryTitleCardWorldPresenter,
        blackout: ImmersiveBlackoutController,
        cinematicWorldAnchor: AnchorEntity
    ) {
        storyTitleCardTransitionCoordinator.bind(
            world: self,
            presenter: presenter,
            blackout: blackout
        )
        cinematicWorldPresentationCoordinator.bind(
            worldAnchor: cinematicWorldAnchor
        )
        chapter03Coordinator?.bind(blackout: blackout)
    }

    private func configureStoryAmbientGunfire(sceneRoot: Entity) {
        storyAmbientGunfireWorldBridge.bind(sceneRoot: sceneRoot)
        do {
            let catalog = try StoryAmbientGunfireCatalogStore().catalog
            let snapshotProvider = StoryAmbientGunfireWorldSnapshotProvider(
                spatialProvider: spatialProvider,
                wallManager: roomSkinningCoordinator.wallManager
            )
            let scheduler = StoryAmbientGunfireScheduler(
                catalog: catalog,
                snapshotProvider: snapshotProvider,
                worldBridge: storyAmbientGunfireWorldBridge,
                random: SeededStoryAmbientRandomSource(
                    seed: StoryAmbientRandomSeed.gunfire
                )
            )
            let lifecycle = StoryAmbientGunfireLifecycleController(
                scheduler: scheduler,
                worldBridge: storyAmbientGunfireWorldBridge
            )
            storyAmbientGunfireLifecycle = lifecycle
            print(
                "[StoryAmbientGunfire] configured startBoundary=storyPropsCommitted " +
                    "gapSeconds=5...45 dryFeet=500...1000 dryGainDB=-12 " +
                    "seed=\(StoryAmbientRandomSeed.gunfire)"
            )
        } catch {
            storyAmbientGunfireLifecycle = nil
            print(
                "[StoryAmbientGunfire] ERROR disabled " +
                    "error=\(error.localizedDescription)"
            )
        }
    }

    private func configureStoryAmbientCounty(sceneRoot: Entity) {
        storyAmbientCountyWorldBridge.bind(sceneRoot: sceneRoot)
        storyAmbientCountySecondaryWorldBridge.bind(sceneRoot: sceneRoot)
        do {
            let catalog = try StoryAmbientCountyCatalogStore().catalog
            let snapshotProvider = StoryAmbientGunfireWorldSnapshotProvider(
                spatialProvider: spatialProvider,
                wallManager: roomSkinningCoordinator.wallManager
            )
            let primaryScheduler = StoryAmbientGunfireScheduler(
                channel: .county,
                catalog: catalog,
                snapshotProvider: snapshotProvider,
                worldBridge: storyAmbientCountyWorldBridge,
                random: SeededStoryAmbientRandomSource(
                    seed: StoryAmbientRandomSeed.county
                )
            )
            let secondaryScheduler = StoryAmbientGunfireScheduler(
                channel: .countySecondary,
                catalog: catalog,
                snapshotProvider: snapshotProvider,
                worldBridge: storyAmbientCountySecondaryWorldBridge,
                random: SeededStoryAmbientRandomSource(
                    seed: StoryAmbientRandomSeed.countySecondary
                )
            )
            storyAmbientCountyLifecycle = StoryAmbientGunfireLifecycleController(
                channel: .county,
                scheduler: primaryScheduler,
                worldBridge: storyAmbientCountyWorldBridge
            )
            storyAmbientCountySecondaryLifecycle =
                StoryAmbientGunfireLifecycleController(
                    channel: .countySecondary,
                    scheduler: secondaryScheduler,
                    worldBridge: storyAmbientCountySecondaryWorldBridge
                )
            print(
                "[StoryAmbientCounty] configured " +
                    "layers=2 startBoundary=storyPropsCommitted " +
                    "gapSeconds=5...15 distantFeet=50 sourceGainDB=0 " +
                    "primarySeed=\(StoryAmbientRandomSeed.county) " +
                    "secondarySeed=\(StoryAmbientRandomSeed.countySecondary)"
            )
        } catch {
            storyAmbientCountyLifecycle = nil
            storyAmbientCountySecondaryLifecycle = nil
            storyAmbientCountyWorldBridge.unbind(
                reason: "configurationFailed"
            )
            storyAmbientCountySecondaryWorldBridge.unbind(
                reason: "configurationFailed"
            )
            print(
                "[StoryAmbientCounty] ERROR disabled " +
                    "error=\(error.localizedDescription)"
            )
        }
    }

    private func configureStoryAmbientAircraft(sceneRoot: Entity) {
        storyAmbientAircraftWorldBridge.bind(sceneRoot: sceneRoot)
        do {
            let catalog = try StoryAmbientAircraftCatalogStore().catalog
            let scheduler = StoryAmbientAircraftScheduler(
                catalog: catalog,
                worldBridge: storyAmbientAircraftWorldBridge
            )
            storyAmbientAircraftLifecycle =
                StoryAmbientAircraftLifecycleController(
                    scheduler: scheduler,
                    worldBridge: storyAmbientAircraftWorldBridge
                )
            print(
                "[StoryAmbientAircraft] configured " +
                    "startBoundary=storyPropsCommitted gapSeconds=5...20 " +
                    "originHeightFeet=10...15 sourceGainDB=0"
            )
        } catch {
            storyAmbientAircraftLifecycle = nil
            print(
                "[StoryAmbientAircraft] ERROR disabled " +
                    "error=\(error.localizedDescription)"
            )
        }
    }

    private func configureStoryAmbientPresentationCallbacks() {
        storyTitleCardTransitionCoordinator
            .onPresentationActivityChanged = { [weak self] active, reason in
                self?.storyAmbientGunfireLifecycle?.setTitleCardActive(
                    active,
                    reason: reason
                )
                self?.storyAmbientCountyLifecycle?.setTitleCardActive(
                    active,
                    reason: reason
                )
                self?.storyAmbientCountySecondaryLifecycle?
                    .setTitleCardActive(
                        active,
                        reason: reason
                    )
                self?.storyAmbientAircraftLifecycle?.setTitleCardActive(
                    active,
                    reason: reason
                )
            }
    }

    func makeSceneRoot(
        initialAtmosphere: PlagueForestAtmosphere,
        atmosphereRevision: Int
    ) async -> AnchorEntity {
        if let sceneRoot {
            return sceneRoot
        }

        let root = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
        root.name = "GravitasPlague_PhaseOne_SceneRoot"
        #if GR_MIND_EYE_QUALIFICATION
        if MindEyeQualificationFeatureControl.isMindEyeEnabled {
            await MindEyeReleaseQualificationHooks.shared.install(
                snapshotProvider: { @MainActor [weak self] in
                    guard let self else {
                        return MindEyeReleaseResourceSnapshot.empty()
                    }
                    return await self.mindEyePresentationCoordinator
                        .releaseResourceSnapshot()
                }
            )
        } else {
            await MindEyeReleaseQualificationHooks.shared.install(
                snapshotProvider: { @MainActor in
                    MindEyeReleaseResourceSnapshot.empty()
                }
            )
        }
        MindEyeReleaseQualificationHooks.shared.fireAndForget(.immersiveEntered)
        #endif
        PlagueNativeBloomInstaller.installStrictBloom(
            on: root
        )
        configureStoryAmbientGunfire(sceneRoot: root)
        configureStoryAmbientCounty(sceneRoot: root)
        configureStoryAmbientAircraft(sceneRoot: root)
        configureStoryAmbientPresentationCallbacks()

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
        TuringRichHeadsetAudioRoute.install(on: head)

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
        turingWalkieBundleController.installIfNeeded(
            sceneRoot: root,
            wallManager: roomSkinningCoordinator.wallManager,
            occupancyRegistry: wallPropOccupancyRegistry
        )
        turingWindowBundleController.installIfNeeded(
            sceneRoot: root,
            wallManager: roomSkinningCoordinator.wallManager,
            occupancyRegistry: wallPropOccupancyRegistry
        )
        turingDoorBundleController.installIfNeeded(
            sceneRoot: root,
            wallManager: roomSkinningCoordinator.wallManager,
            occupancyRegistry: wallPropOccupancyRegistry
        )
        turingRollingBenchBundleController.installIfNeeded(
            sceneRoot: root,
            wallManager: roomSkinningCoordinator.wallManager,
            occupancyRegistry: wallPropOccupancyRegistry
        )
        if MindEyeQualificationFeatureControl.isMindEyeEnabled {
            mindEyePresentationCoordinator.bindPlacementProviders([
                turingWalkieBundleController,
                turingRollingBenchBundleController
            ])
            mindEyeRuntimeLifecycle.start()
            await TuringHighMemoryPreflightCoordinator.shared.installMindEye(
                mindEyeRuntimeLifecycle
            )
        }
        StoryInteractionPresentationCoordinator.shared.register(
            turingStoryWalkieInteractionController
        )
        StoryInteractionPresentationCoordinator.shared.register(
            turingStoryDadFrameInteractionController
        )
        StoryInteractionPresentationCoordinator.shared.register(
            turingRollingBenchBundleController
                .crankRadioInteractionController
        )
        StoryInteractionPresentationCoordinator.shared.register(
            turingRollingBenchBundleController
                .hamReceiverInteractionController
        )
        StoryInteractionPresentationCoordinator.shared.register(
            turingDoorBundleController
        )
        StoryInteractionPresentationCoordinator.shared.start()
        let battle01 = Battle01Coordinator(
            sceneRoot: root,
            door: turingDoorBundleController,
            clock: ProductionBattleClock(),
            richVocalChannel: audioController,
            onEnemyPrepared: { [weak self] enemyID, controller in
                self?.prepareBattle01EnemyAudioAndCallbacks(
                    enemyID: enemyID,
                    controller: controller
                )
            },
            onEnemyRemoved: { [weak self] enemyID in
                self?.audioController.stopHostAudioSource(id: enemyID)
            },
            onEnemyMemoryPresenceChanged: { [weak self] present, reason in
                self?.turingStoryWalkieInteractionController
                    .setBattle01GrandmaMemoryPresent(
                        present,
                        reason: reason
                    )
            },
            onPostBattleHold: { [weak self] event in
                guard let completion = self?.prologueCompletionCoordinator else {
                    print(
                        "[TuringProloguePostBattle] ERROR completion owner unavailable"
                    )
                    return
                }
                do {
                    try await completion.battleRuntimeReleased(event)
                } catch {
                    print(
                        "[TuringProloguePostBattle] ERROR hub unlock failed " +
                            "error=\(error.localizedDescription)"
                    )
                }
            },
            playerTargetProvider: { [weak self] in
                self?.spatialProvider.currentPose()?.headPosition
            },
            onPlayerDamage: { [weak self] amount in
                self?.audioController.playRandomPlayerDamageHit()
                self?.onPlayerDamaged?(Int(amount))
            }
        )
        let prologueRouter = PrologueStoryActionRouter(battle01: battle01)
        let completionCoordinator = TuringPrologueCompletionCoordinator(
            battleRouter: prologueRouter,
            walkie: turingStoryWalkieInteractionController,
            dadFrame: turingStoryDadFrameInteractionController,
            hamReceiver: turingRollingBenchBundleController
                .hamReceiverInteractionController
        )
        battle01Coordinator = battle01
        chapter01RobotEncounterCoordinator =
            Chapter01RobotEncounterCoordinator(
                sceneRoot: root,
                hudRoot: head,
                door: turingDoorBundleController,
                spatialProvider: spatialProvider,
                approachTargetClamp: { [weak self] target in
                    guard let self else { return target }
                    return Chapter01RobotApproachController.clampToMappedFloor(
                        target,
                        floors: Array(
                            self.roomSkinningCoordinator.wallManager
                                .floorCandidates.values
                        )
                    )
                },
                rewardAnchorResolver: { [weak self] name in
                    self?.turingRollingBenchBundleController
                        .authoredRewardAnchor(named: name)
                },
                onEnemyPrepared: { [weak self] enemyID, controller in
                    self?.prepareChapter01RobotAudioAndCallbacks(
                        enemyID: enemyID,
                        controller: controller
                    )
                },
                onEnemyRemoved: { [weak self] enemyID in
                    self?.audioController.stopHostAudioSource(id: enemyID)
                },
                onPlayerDamage: { [weak self] amount in
                    self?.audioController.playRandomPlayerDamageHit()
                    self?.onPlayerDamaged?(amount)
                },
                onPlayerDeath: { [weak self] in
                    self?.handleChapter01PlayerDeath(source: .robot)
                }
            )
        let dadWindow = Chapter01DadWindowCoordinator(
            windowBundle: turingWindowBundleController
        )
        let postRobotInteractions = Chapter01PostRobotInteractionCoordinator(
            dadFrame: turingStoryDadFrameInteractionController,
            walkie: turingStoryWalkieInteractionController,
            hamReceiver: turingRollingBenchBundleController
                .hamReceiverInteractionController
        )
        let preDadFinalBattleBoundary = Chapter01PreDadFinalBattleBoundary()
        let dadFinalBattle = Chapter01DadFinalBattleCoordinator(
            sceneRoot: root,
            door: turingDoorBundleController,
            clock: ProductionBattleClock(),
            richVocalChannel: audioController,
            onEnemyPrepared: { [weak self] enemyID, controller in
                self?.prepareChapter01DadBattleAudioAndCallbacks(
                    enemyID: enemyID,
                    controller: controller
                )
            },
            onEnemyRemoved: { [weak self] enemyID in
                self?.audioController.stopHostAudioSource(id: enemyID)
            },
            playerTargetProvider: { [weak self] in
                self?.spatialProvider.currentPose()?.headPosition
            },
            onPlayerContactFeedback: { [weak self] amount in
                self?.audioController.playRandomPlayerDamageHit()
                self?.onPlayerDamaged?(amount)
            },
            onPlayerDeath: { [weak self] in
                self?.handleChapter01PlayerDeath(source: .dadFinalBattle)
            }
        )
        let dadFinalBattleActionRouter =
            Chapter01DadFinalBattleActionRouter(
                battle: dadFinalBattle
            )
        let finalDadFrameInteractions =
            Chapter01FinalDadFrameInteractionCoordinator(
                dadFrame: turingStoryDadFrameInteractionController
            )
        preDadFinalBattleBoundary.sink = dadFinalBattleActionRouter
        let chapterCoordinator = Chapter01Coordinator(
            walkie: turingStoryWalkieInteractionController,
            dad: dadWindow,
            postRobotInteractions: postRobotInteractions,
            preDadFinalBattleBoundary: preDadFinalBattleBoundary,
            dadFinalBattleActionRouter: dadFinalBattleActionRouter,
            finalDadFrameInteractions: finalDadFrameInteractions,
            startRobot: { [weak self] chapterRunID, transitionLease, sink in
                guard let self else {
                    throw Chapter01Error.openingResourceUnavailable(
                        "The immersive Chapter owner was released."
                    )
                }
                try await self.startChapter01RobotEncounter(
                    chapterRunID: chapterRunID,
                    storyTransitionLease: transitionLease,
                    completionSink: sink
                )
            },
            cancelRobot: { [weak self] reason in
                await self?.chapter01RobotEncounterCoordinator?.cancel(
                    reason: reason
                )
            }
        )
        chapterCoordinator.onEpisodeBoundary = { [weak self] event in
            guard let self else {
                throw StoryTitleCardError.missingRouteOwner
            }
            try await self.handleStoryEpisodeBoundary(event)
        }
        completionCoordinator.onEpisodeBoundary = { [weak self] event in
            guard let self else {
                throw StoryTitleCardError.missingRouteOwner
            }
            try await self.handleStoryEpisodeBoundary(event)
        }
        dadFinalBattle.setCompletionSink(chapterCoordinator)

        let chapter02Surfaces = Chapter02SurfaceSequenceCoordinator(
            walkie: turingStoryWalkieInteractionController,
            dadFrame: turingStoryDadFrameInteractionController,
            crankRadio: turingRollingBenchBundleController
                .crankRadioInteractionController,
            hamReceiver: turingRollingBenchBundleController
                .hamReceiverInteractionController
        )
        let chapter02WindowWoman = Chapter02WindowWomanCoordinator(
            windowBundle: turingWindowBundleController,
            sceneRoot: root
        )
        let chapter02WomanBattle = Chapter02WomanBattleCoordinator(
            sceneRoot: root,
            door: turingDoorBundleController,
            richVocalChannel: audioController,
            onEnemyPrepared: { [weak self] enemyID, controller in
                self?.prepareChapter02WomanAudioAndCallbacks(
                    enemyID: enemyID,
                    controller: controller
                )
            },
            onEnemyRemoved: { [weak self] enemyID in
                self?.audioController.stopHostAudioSource(id: enemyID)
            },
            playerTargetProvider: { [weak self] in
                self?.spatialProvider.currentPose()?.headPosition
            },
            onPlayerDamage: { [weak self] amount in
                self?.audioController.playRandomPlayerDamageHit()
                self?.onPlayerDamaged?(Int(amount))
            }
        )
        let chapter02 = Chapter02Coordinator(
            surfaces: chapter02Surfaces,
            womanWindow: chapter02WindowWoman,
            womanBattle: chapter02WomanBattle
        )
        chapter02.onEpisodeBoundary = { [weak self] event in
            guard let self else {
                throw StoryTitleCardError.missingRouteOwner
            }
            try await self.handleStoryEpisodeBoundary(event)
        }
        let chapter03Presenter = Chapter03LightTunnelPresenter(
            cinematicWorld: cinematicWorldPresentationCoordinator
        )
        let chapter03Music = Chapter03LightTunnelMusicController()
        let chapter03AngelPrerecording = StorySpatialPrerecordingPlayer()
        let chapter03LightTunnel = Chapter03LightTunnelCoordinator(
            presenter: chapter03Presenter,
            music: chapter03Music,
            angelPrerecording: chapter03AngelPrerecording,
            cinematicWorld: cinematicWorldPresentationCoordinator,
            deviceTransformProvider: { [weak self] in
                self?.spatialProvider.currentTrackedDeviceTransform()
            }
        )
        let chapter03Surfaces = Chapter03SurfaceSequenceCoordinator(
            walkie: turingStoryWalkieInteractionController,
            hamReceiver: turingRollingBenchBundleController
                .hamReceiverInteractionController,
            crankRadio: turingRollingBenchBundleController
                .crankRadioInteractionController
        )
        let chapter03RoomPresentation = Chapter03RoomPresentationController(
            roots: [
                "door": turingDoorBundleController.root,
                "window": turingWindowBundleController.root,
                "walkie": turingWalkieBundleController.root,
                "rollingBench": turingRollingBenchBundleController.root,
                "poster": wallPosterUIController.root
            ],
            adjustments: turingStoryPlacementAdjustmentCoordinator,
            surfaces: chapter03Surfaces,
            fingerprintProvider: { [weak self] in
                guard let self else {
                    throw Chapter03Error.storyStageNotEstablished
                }
                return try self.establishedLayoutFingerprint()
            }
        )
        let chapter03BikerMusic = Chapter03BattleMusicController()
        let chapter03MikeMusic = Chapter03BattleMusicController()
        let chapter03BikerBattle = Chapter03BikerBattleCoordinator(
            sceneRoot: root,
            door: turingDoorBundleController,
            music: chapter03BikerMusic,
            richVocalChannel: audioController,
            onEnemyPrepared: { [weak self] enemyID, controller in
                self?.prepareChapter03BattleAudioAndCallbacks(
                    enemyID: enemyID,
                    controller: controller,
                    archetype: .biker,
                    label: "biker"
                )
            },
            onEnemyRemoved: { [weak self] enemyID in
                self?.audioController.stopHostAudioSource(id: enemyID)
            },
            playerTargetProvider: { [weak self] in
                self?.spatialProvider.currentPose()?.headPosition
            },
            onPlayerContactFeedback: { [weak self] amount in
                self?.audioController.playRandomPlayerDamageHit()
                self?.onPlayerDamaged?(amount)
            },
            onPlayerDeath: { [weak self] in
                self?.handleChapter01PlayerDeath(source: .chapter03Biker)
            }
        )
        let chapter03MikeBattle = Chapter03MikeBattleCoordinator(
            sceneRoot: root,
            door: turingDoorBundleController,
            music: chapter03MikeMusic,
            roomPresentation: chapter03RoomPresentation,
            richVocalChannel: audioController,
            onEnemyPrepared: { [weak self] enemyID, controller in
                self?.prepareChapter03BattleAudioAndCallbacks(
                    enemyID: enemyID,
                    controller: controller,
                    archetype: .neighbor,
                    label: "bigMike"
                )
            },
            onEnemyRemoved: { [weak self] enemyID in
                self?.audioController.stopHostAudioSource(id: enemyID)
            },
            playerTargetProvider: { [weak self] in
                self?.spatialProvider.currentPose()?.headPosition
            },
            onPlayerContactFeedback: { [weak self] amount in
                self?.audioController.playRandomPlayerDamageHit()
                self?.onPlayerDamaged?(amount)
            },
            onFinalAngelDeathSequenceBegan: { [weak self] in
                self?.storyAmbientGunfireLifecycle?
                    .finalAngelDeathSequenceBegan(
                        reason: "chapter03.mike.nonlethalDefeatThreshold"
                    )
                self?.storyAmbientCountyLifecycle?
                    .finalAngelDeathSequenceBegan(
                        reason: "chapter03.mike.nonlethalDefeatThreshold"
                    )
                self?.storyAmbientCountySecondaryLifecycle?
                    .finalAngelDeathSequenceBegan(
                        reason: "chapter03.mike.nonlethalDefeatThreshold"
                    )
                self?.storyAmbientAircraftLifecycle?
                    .finalAngelDeathSequenceBegan(
                        reason: "chapter03.mike.nonlethalDefeatThreshold"
                    )
            },
            onPlayerDeath: { [weak self] in
                self?.handleChapter01PlayerDeath(source: .chapter03Mike)
            }
        )
        let chapter03 = Chapter03Coordinator(
            bikerBattle: chapter03BikerBattle,
            surfaces: chapter03Surfaces,
            mikeBattle: chapter03MikeBattle,
            roomPresentation: chapter03RoomPresentation,
            lightTunnel: chapter03LightTunnel,
            richVocalChannel: audioController,
            layoutFingerprintProvider: { [weak self] in
                guard let self else {
                    throw Chapter03Error.storyStageNotEstablished
                }
                return try self.establishedLayoutFingerprint()
            }
        )
        chapter03.onEndCardRequested = { [weak self] request, lease, blackoutID in
            guard let self else {
                throw StoryTitleCardError.missingRouteOwner
            }
            try self.storyTitleCardTransitionCoordinator.accept(
                request,
                ownership: .transferredAlreadyFullBlack(
                    lease: lease,
                    blackoutRequestID: blackoutID
                )
            )
        }
        chapter03.onFailure = { [weak self] error in
            self?.showTemporaryInstructionHUD(
                "Chapter 3 failed: \(error.localizedDescription)",
                clearAfterSeconds: 5,
                reason: "chapter03LightTunnelFailed"
            )
            self?.onStoryEpisodePickerRequested?("chapter03LightTunnelFailed")
        }
        let completionRouter = TuringStoryCompletionRouter(
            prologue: completionCoordinator,
            chapter01: chapterCoordinator,
            chapter02: chapter02,
            chapter03: chapter03
        )
        chapter01DadWindowCoordinator = dadWindow
        chapter01DadFinalBattleCoordinator = dadFinalBattle
        chapter01Coordinator = chapterCoordinator
        chapter02WindowWomanCoordinator = chapter02WindowWoman
        chapter02WomanBattleCoordinator = chapter02WomanBattle
        chapter02Coordinator = chapter02
        chapter03Coordinator = chapter03
        storyCompletionRouter = completionRouter
        let highMemoryPreflight = StoryTuringHighMemoryPreflightAdapter(
            door: turingDoorBundleController,
            battleRuntime: battle01
        )
        turingHighMemoryPreflightAdapter = highMemoryPreflight
        await TuringHighMemoryPreflightCoordinator.shared.install(
            highMemoryPreflight
        )
        prologueStoryActionRouter = prologueRouter
        prologueCompletionCoordinator = completionCoordinator
        await TuringEpisodeFlowController.shared
            .setCompletionEventSink(completionRouter)
        TuringStoryStateTeleportCoordinator.shared.attach(self)
        turingStoryPlacementAdjustmentCoordinator.install(
            sceneRoot: root
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

        #if GR_MIND_EYE_QUALIFICATION
        MindEyeReleaseQualificationHooks.shared.fireAndForget(.storySystemsReady)
        #endif

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

    func beginTuringPlacementAdjustment(
        propID: TuringStoryPropID,
        worldPoint: SIMD3<Float>
    ) {
        turingStoryPlacementAdjustmentCoordinator.begin(
            propID: propID,
            worldPoint: worldPoint
        )
    }

    func updateTuringPlacementAdjustment(
        worldPoint: SIMD3<Float>
    ) {
        turingStoryPlacementAdjustmentCoordinator.update(
            worldPoint: worldPoint
        )
    }

    func endTuringPlacementAdjustment(
        commit: Bool
    ) {
        turingStoryPlacementAdjustmentCoordinator.end(
            commit: commit
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

    private func prepareBattle01EnemyAudioAndCallbacks(
        enemyID: UUID,
        controller: JockRetargetTestController
    ) {
        print(
            "[Battle01Lighting] room-side Grandma uses automatic passthrough lighting explicitIBLReceiver=false"
        )
        audioController.attachHostAudioSource(
            id: enemyID,
            hostRootEntity: controller.rootEntity,
            archetype: .grandma,
            headAudioEntity: controller.characterAudioEmitter,
            breathingStartDelay: 0
        )
        controller.onPunchHit = { [weak self, weak controller] region in
            guard let controller else { return }
            self?.audioController.playConfirmedCharacterFaceHitSound(
                archetype: .grandma,
                enemyID: controller.hordeBenchmarkID,
                hitRegion: region,
                sourceID: enemyID
            )
        }
        controller.onCharacterDamageHit = { [weak self] in
            self?.audioController.playCharacterDamageHit(
                archetype: .grandma,
                enemyID: enemyID,
                sourceID: enemyID
            )
        }
        controller.onCharacterDeath = { [weak self] in
            self?.audioController.playCharacterDeath(
                archetype: .grandma,
                enemyID: enemyID,
                sourceID: enemyID
            )
        }
        controller.onAttackStarted = {
            print("[Battle01] Grandma attack animation started")
        }
    }

    private func prepareChapter01DadBattleAudioAndCallbacks(
        enemyID: UUID,
        controller: JockRetargetTestController
    ) {
        print(
            "[Chapter01DadBattleLighting] room-side Dad uses automatic " +
                "passthrough lighting explicitIBLReceiver=false"
        )
        audioController.attachHostAudioSource(
            id: enemyID,
            hostRootEntity: controller.rootEntity,
            archetype: .dad,
            headAudioEntity: controller.characterAudioEmitter,
            breathingStartDelay: 0
        )
        controller.onPunchHit = { [weak self, weak controller] region in
            guard let controller else { return }
            self?.audioController.playConfirmedCharacterFaceHitSound(
                archetype: .dad,
                enemyID: controller.hordeBenchmarkID,
                hitRegion: region,
                sourceID: enemyID
            )
        }
        controller.onCharacterDamageHit = { [weak self] in
            self?.audioController.playCharacterDamageHit(
                archetype: .dad,
                enemyID: enemyID,
                sourceID: enemyID
            )
        }
        controller.onCharacterDeath = { [weak self] in
            self?.audioController.playCharacterDeath(
                archetype: .dad,
                enemyID: enemyID,
                sourceID: enemyID
            )
        }
        controller.onAttackStarted = {
            print("[Chapter01DadBattle] Dad attack animation started")
        }
    }

    private func prepareChapter02WomanAudioAndCallbacks(
        enemyID: UUID,
        controller: JockRetargetTestController
    ) {
        print(
            "[Chapter02WomanLighting] room-side spouse uses automatic " +
                "passthrough lighting explicitIBLReceiver=false"
        )
        audioController.attachHostAudioSource(
            id: enemyID,
            hostRootEntity: controller.rootEntity,
            archetype: .spouse,
            headAudioEntity: controller.characterAudioEmitter,
            breathingStartDelay: 0
        )
        controller.onPunchHit = { [weak self, weak controller] region in
            guard let controller else { return }
            self?.audioController.playConfirmedCharacterFaceHitSound(
                archetype: .spouse,
                enemyID: controller.hordeBenchmarkID,
                hitRegion: region,
                sourceID: enemyID
            )
        }
        controller.onCharacterDamageHit = { [weak self] in
            self?.audioController.playCharacterDamageHit(
                archetype: .spouse,
                enemyID: enemyID,
                sourceID: enemyID
            )
        }
        controller.onCharacterDeath = { [weak self] in
            self?.audioController.playCharacterDeath(
                archetype: .spouse,
                enemyID: enemyID,
                sourceID: enemyID
            )
        }
        controller.onAttackStarted = {
            print("[Chapter02WomanBattle] spouse attack animation started")
        }
    }

    private func prepareChapter03BattleAudioAndCallbacks(
        enemyID: UUID,
        controller: JockRetargetTestController,
        archetype: PlagueCharacterArchetype,
        label: String
    ) {
        print(
            "[Chapter03BattleLighting] room-side \(archetype.rawValue) uses automatic passthrough lighting explicitIBLReceiver=false"
        )
        audioController.attachHostAudioSource(
            id: enemyID,
            hostRootEntity: controller.rootEntity,
            archetype: archetype,
            headAudioEntity: controller.characterAudioEmitter,
            breathingStartDelay: 0
        )
        controller.onPunchHit = { [weak self, weak controller] region in
            guard let controller else { return }
            self?.audioController.playConfirmedCharacterFaceHitSound(
                archetype: archetype,
                enemyID: controller.hordeBenchmarkID,
                hitRegion: region,
                sourceID: enemyID
            )
        }
        controller.onCharacterDamageHit = { [weak self] in
            self?.audioController.playCharacterDamageHit(
                archetype: archetype,
                enemyID: enemyID,
                sourceID: enemyID
            )
        }
        controller.onCharacterDeath = { [weak self] in
            self?.audioController.playCharacterDeath(
                archetype: archetype,
                enemyID: enemyID,
                sourceID: enemyID
            )
        }
        controller.onAttackStarted = {
            print("[Chapter03Battle] attack animation started label=\(label)")
        }
    }

    private func prepareChapter01RobotAudioAndCallbacks(
        enemyID: UUID,
        controller: JockRetargetTestController
    ) -> (any Chapter01RobotAudioAttachment)? {
        audioController.attachHostAudioSource(
            id: enemyID,
            hostRootEntity: controller.rootEntity,
            archetype: .robot,
            headAudioEntity: controller.characterAudioEmitter,
            breathingStartDelay: 0
        )
        controller.onPunchHit = { [weak self] region in
            self?.audioController.playConfirmedCharacterFaceHitSound(
                archetype: .robot,
                enemyID: enemyID,
                hitRegion: region,
                sourceID: enemyID
            )
        }
        controller.onCharacterDamageHit = { [weak self] in
            self?.audioController.playCharacterDamageHit(
                archetype: .robot,
                enemyID: enemyID,
                sourceID: enemyID
            )
        }
        controller.onCharacterDeath = { [weak self] in
            self?.audioController.playCharacterDeath(
                archetype: .robot,
                enemyID: enemyID,
                sourceID: enemyID
            )
        }
        controller.onAttackStarted = {
            print("[Chapter01Robot] attack animation started")
        }
        return Chapter01RobotAudioAttachmentLease(
            enemyID: enemyID,
            audioController: audioController,
            audioEmitter: controller.characterAudioEmitter
        )
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

    func applyTuringDictationEventToExistingHUD(
        _ event: TuringDictationEvent
    ) {
        switch event {
        case .recordingStarted:
            turingHUDDelayedClearTask?.cancel()
            turingHUDDelayedClearTask = nil
            showInstructionHUD("Listening...")
            print("[TuringHUD] player dictation shown state=listening")

        case .partialTranscript(let text):
            turingHUDDelayedClearTask?.cancel()
            turingHUDDelayedClearTask = nil
            let trimmed = text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if trimmed.isEmpty {
                showInstructionHUD("Listening...")
                print("[TuringHUD] player dictation shown state=listening")
            } else {
                showInstructionHUD(trimmed)
                print("[TuringHUD] player dictation shown state=partial")
            }

        case .finalTranscript(let text),
             .processingStarted(let text):
            turingHUDDelayedClearTask?.cancel()
            turingHUDDelayedClearTask = nil
            let trimmed = text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if trimmed.isEmpty {
                showInstructionHUD("Listening...")
                print("[TuringHUD] player dictation shown state=listening")
            } else {
                showInstructionHUD(trimmed)
                print("[TuringHUD] player dictation shown state=final")
            }

        case .responseAudioStarted(let question):
            turingHUDDelayedClearTask?.cancel()
            turingHUDDelayedClearTask = nil
            let trimmed = question.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard trimmed.isEmpty == false else {
                instructionHUD.clear()
                print(
                    "[TuringHUD] player dictation reminder skipped " +
                        "reason=emptyQuestion"
                )
                return
            }
            showTemporaryInstructionHUD(
                trimmed,
                clearAfterSeconds:
                    turingQuestionReminderDurationSeconds,
                reason: "conversationResponsePlaybackStarted"
            )
            print(
                "[TuringHUD] player dictation reminder shown " +
                    "for TTS playback durationSeconds=" +
                    String(
                        format: "%.2f",
                        turingQuestionReminderDurationSeconds
                    )
            )

        case .questionDisplayExpired:
            turingHUDDelayedClearTask?.cancel()
            turingHUDDelayedClearTask = nil
            instructionHUD.clear()
            print("[TuringHUD] player question cleared; device ellipsis remains")

        case .responseSegmentZeroReady(let clearAfterSeconds):
            turingHUDDelayedClearTask?.cancel()
            print("""
            [TuringHUD] player dictation retained after segment zero ready
              clearAfterSeconds: \(String(format: "%.2f", clearAfterSeconds))
            """)
            turingHUDDelayedClearTask = Task { @MainActor [weak self] in
                try? await Task.sleep(
                    nanoseconds: UInt64(max(0, clearAfterSeconds) * 1_000_000_000)
                )
                guard !Task.isCancelled else { return }
                self?.instructionHUD.clear()
                self?.turingHUDDelayedClearTask = nil
                print("[TuringHUD] player dictation cleared after segment zero ready hold")
            }

        case .responseAudioFinished:
            print(
                "[TuringHUD] TTS playback finished; player dictation " +
                    "reminder retains its seven-second hold"
            )

        case .cancelled:
            turingHUDDelayedClearTask?.cancel()
            turingHUDDelayedClearTask = nil
            instructionHUD.clear()
            print("[TuringHUD] player dictation cleared")

        case .responseFailed(let message):
            showInstructionHUD("Device operation failed.")
            scheduleTuringHUDClear(
                after: 2.0,
                reason: "responseFailure"
            )
            print("""
            [TuringHUD] response failure shown
              error: \(message)
            """)

        case .failed(let message):
            showInstructionHUD("Dictation failed.")
            scheduleTuringHUDClear(
                after: 2.0,
                reason: "dictationFailure"
            )
            print("""
            [TuringHUD] player dictation shown state=failed
              error: \(message)
            """)
        }
    }

    private func scheduleTuringHUDClear(
        after seconds: TimeInterval,
        reason: String
    ) {
        turingHUDDelayedClearTask?.cancel()
        turingHUDDelayedClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)
            )
            guard Task.isCancelled == false else { return }
            self?.instructionHUD.clear()
            self?.turingHUDDelayedClearTask = nil
            print("[TuringHUD] failure cleared reason=\(reason)")
        }
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
            guard operationModeSwitchTask == nil else {
                print(
                    "[PlagueModeSwitch] duplicate Horde scan ignored " +
                        "while mode switch is active"
                )
                return
            }
            beginHordeRoomScanForBenchmark()

        case .switchOperationMode(let mode, let source):
            switchOperationModeFromPoster(
                to: mode,
                source: source
            )

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

        case .startStoryEpisode(let episodeID):
            Task { @MainActor [weak self] in
                await self?.startStoryEpisode(episodeID)
            }

        case .continueStoryEpisode(let episodeID):
            continueStoryEpisode(episodeID)

        case .presentStoryTitleCard(let request):
            do {
                try storyTitleCardTransitionCoordinator.accept(request)
            } catch {
                titleCardTransitionFailed(error, request: request)
            }

        case .requestStoryWalkieBundlePlacement:
            guard operationModeSwitchTask == nil else {
                print(
                    "[PlagueModeSwitch] duplicate Story scan ignored " +
                        "while mode switch is active"
                )
                return
            }
            requestTuringStoryPlacementRoomScan(
                reason: "storyModeRequested"
            )

        case .requestTuringStoryPlacementRoomScan(let reason):
            guard operationModeSwitchTask == nil else {
                print(
                    "[PlagueModeSwitch] duplicate Story scan ignored " +
                        "while mode switch is active reason=\(reason)"
                )
                return
            }
            requestTuringStoryPlacementRoomScan(
                reason: reason
            )

        case .restartTuringStoryPlacementRoomScan(let reason):
            restartTuringStoryPlacementRoomScan(
                reason: reason
            )

        case .updatePortalHDRIAtmosphere(let atmosphere):
            currentStoryWindowAtmosphere = atmosphere
            wallPosterUIController.updateTuringWindowDayNightIcon(
                atmosphere: atmosphere
            )
            if roomSkinningCoordinator.portalRuntimePolicy == .legacyDebug {
                roomSkinningCoordinator.updatePortalContentAtmosphere(atmosphere)
            } else {
                assert(roomSkinningCoordinator.hasInstalledLegacyPortal == false)
            }
            Task { @MainActor [weak self] in
                await self?.turingWindowBundleController
                    .updateAtmosphereIfNeeded(atmosphere)
                await self?.turingDoorBundleController
                    .updateAtmosphereIfNeeded(atmosphere)
            }

        case .updatePortalLoopGainDB(let gainDB):
            hordePortalManager.updatePortalLoopGainDB(gainDB)

        case .updateEnemyCollisionDebugVisible(let visible):
            setEnemyCollisionDebugVisible(visible)
        }
    }

    private func startStoryEpisode(
        _ episodeID: TuringEpisodeID
    ) async {
        if MindEyeQualificationFeatureControl.isMindEyeEnabled {
            _ = await mindEyeRuntimeLifecycle.resetForStoryBoundary(
                scope: .chapterReset,
                reason: "newStoryEpisode.\(episodeID.rawValue)"
            )
        }
        battle01Coordinator?.cancel(
            reason: "newStoryEpisode.\(episodeID.rawValue)"
        )
        if episodeID != .chapter01 {
            Task { @MainActor [weak self] in
                await self?.chapter01Coordinator?.cancel(
                    reason: "newStoryEpisode.\(episodeID.rawValue)"
                )
            }
        }
        if episodeID != .chapter02 {
            Task { @MainActor [weak self] in
                await self?.chapter02Coordinator?.cancel(
                    reason: "newStoryEpisode.\(episodeID.rawValue)"
                )
            }
        }
        if episodeID != .chapter03 {
            Task { @MainActor [weak self] in
                await self?.chapter03Coordinator?.cancel(
                    reason: "newStoryEpisode.\(episodeID.rawValue)"
                )
            }
        }
        prologueStoryActionRouter?.reset(
            reason: "newStoryEpisode.\(episodeID.rawValue)"
        )
        if hordeBenchmarkRunning {
            stopHordeBenchmark()
        }

        guard let episode = TuringEpisodeCatalog.descriptor(for: episodeID) else {
            print(
                """
                [TuringStory] ERROR missing episode descriptor
                  episodeID: \(episodeID.rawValue)
                """
            )
            return
        }

        turingStoryWalkieInteractionController
            .episodeStarted(episodeID)

        if episodeID == .chapter01 {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.chapter01Coordinator?.beginAtRoot()
                } catch {
                    self.showTemporaryInstructionHUD(
                        "Chapter unavailable. Check required window and animation assets.",
                        clearAfterSeconds: 5,
                        reason: "chapter01OpeningUnavailable"
                    )
                    print(
                        "[Chapter01] ERROR root start failed: \(error.localizedDescription)"
                    )
                }
            }
            print(
                "[TuringStory] Chapter 01 logical start requested noRescan=true"
            )
            return
        }

        if episodeID == .chapter02 {
            Task { @MainActor [weak self] in
                guard let self,
                      let chapter02Coordinator = self.chapter02Coordinator else {
                    return
                }
                do {
                    let transitionID = UUID()
                    let lease = try await self.acquireTitleCardTransitionLease(
                        transitionID: transitionID,
                        source: "directChapter02Start"
                    )
                    try await chapter02Coordinator.beginAtRoot(
                        transitionLease: lease
                    )
                    try await chapter02Coordinator.titleCardDidFullyFade(
                        requestID: transitionID
                    )
                } catch {
                    self.showTemporaryInstructionHUD(
                        "Chapter unavailable. Check required window, voice, and animation assets.",
                        clearAfterSeconds: 5,
                        reason: "chapter02OpeningUnavailable"
                    )
                    print(
                        "[Chapter02] ERROR root start failed: \(error.localizedDescription)"
                    )
                }
            }
            print("[TuringStory] Chapter 02 logical start requested noRescan=true")
            return
        }

        roomSkinningCoordinator.cancelRoomSkinning()

        print(
            """
            [TuringStory] starting episode placeholder
              episodeID: \(episodeID.rawValue)
              title: \(episode.title)
              script: \(episode.scriptResourcePath)
              activeHordeStopped: true
              runtimeReady: false
              qwenSmokeAutoRun: false
            """
        )
    }

    private func switchOperationModeFromPoster(
        to destination: PlagueDemoSession.PlagueOperationMode,
        source: String
    ) {
        guard destination == .story || destination == .horde else {
            print(
                "[PlagueModeSwitch] ignored unsupported destination=" +
                    "\(destination.rawValue) source=\(source)"
            )
            return
        }

        operationModeSwitchGeneration += 1
        let generation = operationModeSwitchGeneration
        let previousSwitchTask = operationModeSwitchTask
        previousSwitchTask?.cancel()

        operationModeSwitchTask = Task { @MainActor [weak self] in
            await previousSwitchTask?.value

            guard let self else { return }
            defer {
                if self.operationModeSwitchGeneration == generation {
                    self.operationModeSwitchTask = nil
                }
            }
            guard !Task.isCancelled,
                  self.operationModeSwitchGeneration == generation else {
                print(
                    "[PlagueModeSwitch] superseded before teardown " +
                        "destination=\(destination.rawValue) " +
                        "generation=\(generation)"
                )
                return
            }
            let reason =
                "posterModeSwitch.\(source).\(destination.rawValue).\(generation)"

            print(
                "[PlagueModeSwitch] teardown started " +
                    "destination=\(destination.rawValue) " +
                    "generation=\(generation) source=\(source)"
            )

            await self.tearDownOperationModeRuntime(reason: reason)

            guard !Task.isCancelled,
                  self.operationModeSwitchGeneration == generation else {
                print(
                    "[PlagueModeSwitch] superseded after teardown " +
                        "destination=\(destination.rawValue) " +
                        "generation=\(generation)"
                )
                return
            }

            switch destination {
            case .story:
                guard let onStoryModeSwitchRuntimeTornDown =
                        self.onStoryModeSwitchRuntimeTornDown else {
                    print(
                        "[PlagueModeSwitch] Story scan blocked " +
                            "reason=missingTeardownCompletionSink " +
                            "source=\(source)"
                    )
                    return
                }
                onStoryModeSwitchRuntimeTornDown(source)
                guard case .preparing =
                        TuringStoryStageCoordinator.shared.state else {
                    print(
                        "[PlagueModeSwitch] Story scan blocked " +
                            "reason=stagePreparationNotStarted " +
                            "source=\(source)"
                    )
                    return
                }
                self.requestTuringStoryPlacementRoomScan(
                    reason: reason
                )

            case .horde:
                self.beginHordeRoomScanForBenchmark()

            case .walkLoop:
                return
            }

            print(
                "[PlagueModeSwitch] destination scan started " +
                    "destination=\(destination.rawValue) " +
                    "generation=\(generation) source=\(source)"
            )
        }
    }

    private func tearDownOperationModeRuntime(
        reason: String
    ) async {
        TuringMemoryBudgetProbe.log(label: "mindEye.operationTeardown.before")
        if MindEyeQualificationFeatureControl.isMindEyeEnabled {
            _ = await mindEyeRuntimeLifecycle.resetForStoryBoundary(
                scope: .operationMode,
                reason: reason
            )
            await MindEyeAssetMemoryManager.shared.forceEvictAll(
                reason: "operationMode.\(reason)"
            )
            await MindEyeAuthoredFrameTrackStore.shared.forceEvictAll(
                reason: "operationMode.\(reason)"
            )
        }
        TuringMemoryBudgetProbe.log(label: "mindEye.operationTeardown.after")
        await storyAmbientGunfireLifecycle?.deactivateAndWait(
            reason: "operationModeTeardown.\(reason)"
        )
        await storyAmbientCountyLifecycle?.deactivateAndWait(
            reason: "operationModeTeardown.\(reason)"
        )
        await storyAmbientCountySecondaryLifecycle?.deactivateAndWait(
            reason: "operationModeTeardown.\(reason)"
        )
        await storyAmbientAircraftLifecycle?.deactivateAndWait(
            reason: "operationModeTeardown.\(reason)"
        )
        turingHUDDelayedClearTask?.cancel()
        turingHUDDelayedClearTask = nil
        instructionHUD.clear()
        turingStoryPlacementAdjustmentCoordinator.cancel(
            reason: reason
        )
        pendingTuringDebugRescanReason = nil
        activeTuringDebugRescanAttempt = nil
        pendingTuringPlacementScanReasons.removeAll()
        await turingStoryWallLayoutCoordinator.cancelAndWait(
            reason: reason
        )
        turingHUDDelayedClearTask?.cancel()
        turingHUDDelayedClearTask = nil
        instructionHUD.clear()
        cancelTuringStoryPlacementRoomScan(reason: reason)
        turingStoryPlacementScanCompleted = false
        turingStoryPlacementSpinResult = nil
        turingStoryScanSpinTracker.reset()

        stopHordeBenchmark()
        resetHordeBenchmarkDeathPresentation()
        jockRetargetController?.stopFollowDemo()
        jockRetargetController?.stopClip()
        jockRetargetController?.hide()
        audioController.stopAllAudio()

        storyTitleCardTransitionCoordinator.reset(reason: reason)
        StoryModeActionCoordinator.shared.reset(reason: reason)
        battle01Coordinator?.cancel(reason: reason)
        prologueStoryActionRouter?.reset(reason: reason)
        prologueCompletionCoordinator?.reset(reason: reason)

        await chapter01Coordinator?.cancel(reason: reason)
        await chapter02Coordinator?.cancel(reason: reason)
        await chapter03Coordinator?.cancel(reason: reason)
        await TuringEpisodeFlowController.shared.resetEpisode(
            reason: reason
        )
        await turingStoryWalkieInteractionController.shutdown(
            reason: reason
        )
        await turingStoryDadFrameInteractionController.shutdown(
            reason: reason
        )
        await turingRollingBenchBundleController
            .crankRadioInteractionController
            .shutdown(reason: reason)
        await turingRollingBenchBundleController
            .hamReceiverInteractionController
            .shutdown(reason: reason)
        await TuringFlowMediaCueCoordinator.shared.stopAll(
            reason: reason
        )
        await StoryInteractionArbiter.shared.reset(reason: reason)

        TuringStoryWalkieAudioRoute.clear(reason: reason)
        TuringRollingBenchAudioRoute.clear(reason: reason)
        TuringHamReceiverAudioRoute.clear(reason: reason)

        turingStoryWallLayoutCoordinator.resetForRetry()

        turingStoryWalkieInteractionController.walkieRemoved(
            reason: reason
        )
        turingStoryDadFrameInteractionController.dadFrameRemoved(
            reason: reason
        )
        turingDoorBundleController.reset(reason: reason)
        turingRollingBenchBundleController.reset(reason: reason)
        turingWindowBundleController.reset(reason: reason)
        turingWalkieBundleController.reset(reason: reason)
        wallPosterUIController.resetPlacement(reason: reason)

        hordePortalManager.reset()
        roomSkinningCoordinator.cancelRoomSkinning()
        lastWallPosterPlacementAttempt = nil
        onWallPosterUIActiveChanged?(false)

        print(
            "[PlagueModeSwitch] teardown completed " +
                "reason=\(reason) storyRemoved=true hordeRemoved=true"
        )
        #if GR_MIND_EYE_QUALIFICATION
        MindEyeReleaseQualificationHooks.shared.fireAndForget(.operationModeTornDown)
        #endif
    }

    private func continueStoryEpisode(
        _ episodeID: TuringEpisodeID
    ) {
        guard episodeID == .chapter01 || episodeID == .chapter02 else {
            print(
                "[TuringStory] ERROR unsupported immersive continuation episodeID=\(episodeID.rawValue)"
            )
            return
        }

        battle01Coordinator?.cancel(
            reason: "continueStoryEpisode.\(episodeID.rawValue)"
        )
        prologueStoryActionRouter?.reset(
            reason: "continueStoryEpisode.chapter01"
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            if MindEyeQualificationFeatureControl.isMindEyeEnabled {
                _ = await self.mindEyeRuntimeLifecycle.resetForStoryBoundary(
                    scope: .chapterReset,
                    reason: "continueStoryEpisode.\(episodeID.rawValue)"
                )
            }
            do {
                if episodeID == .chapter02 {
                    guard let chapter02Coordinator = self.chapter02Coordinator,
                          let snapshot = await Chapter02ProgressStore.shared
                            .currentSnapshot() else {
                        throw Chapter02Error.stageNotEstablished
                    }
                    let transitionID = UUID()
                    let lease = try await self.acquireTitleCardTransitionLease(
                        transitionID: transitionID,
                        source: "directChapter02Continue"
                    )
                    _ = try await chapter02Coordinator
                        .resumeFromSavedCheckpoint(
                            snapshot: snapshot,
                            transitionLease: lease
                        )
                    try await chapter02Coordinator.titleCardDidFullyFade(
                        requestID: transitionID
                    )
                    return
                }
                guard let chapter01Coordinator =
                        self.chapter01Coordinator else {
                    throw Chapter01Error.openingResourceUnavailable(
                        "The Chapter coordinator is not installed."
                    )
                }
                try await chapter01Coordinator
                    .resumeFromSavedCheckpoint()
            } catch {
                self.showTemporaryInstructionHUD(
                    "Chapter continuation unavailable.",
                    clearAfterSeconds: 5,
                    reason: "\(episodeID.rawValue)ContinueUnavailable"
                )
                print(
                    "[\(episodeID.rawValue)] ERROR continue failed: \(error.localizedDescription)"
                )
            }
        }

        print(
            "[TuringStory] \(episodeID.rawValue) logical continuation requested noRescan=true"
        )
    }

    private func restartTuringStoryPlacementRoomScan(
        reason: String
    ) {
        guard !turingStoryWallLayoutCoordinator.isPlanningOrCommitting else {
            pendingTuringDebugRescanReason = reason
            print("""
            [TuringRoomScanDebug] repeat queued
              reason: \(reason)
              activeLayoutState: \(turingStoryWallLayoutCoordinator.state.rawValue)
              action: start_after_active_layout_finishes
            """)
            return
        }

        turingStoryPlacementAdjustmentCoordinator.cancel(
            reason: "debugRoomRescan.\(reason)"
        )
        battle01Coordinator?.cancel(reason: "roomRescan.\(reason)")
        Task { @MainActor [weak self] in
            await self?.chapter01Coordinator?.cancel(
                reason: "roomRescan.\(reason)"
            )
            await self?.chapter02Coordinator?.cancel(
                reason: "roomRescan.\(reason)"
            )
            await self?.chapter03Coordinator?.cancel(
                reason: "roomRescan.\(reason)"
            )
        }
        prologueStoryActionRouter?.reset(reason: "roomRescan.\(reason)")
        roomSkinningCoordinator.wallManager
            .clearRetainedPlacementWallSnapshot(
                reason: "debugRoomRescan.\(reason)"
            )

        turingDebugRescanAttempt += 1
        let attempt = turingDebugRescanAttempt
        let previousDoorPlaced = turingDoorBundleController.isPlaced
        let previousRollingBenchPlaced = turingRollingBenchBundleController.isPlaced
        let previousWindowPlaced = turingWindowBundleController.isPlaced
        let previousWalkiePlaced = turingWalkieBundleController.isPlaced
        let previousPosterPlaced = wallPosterUIController.isLocked

        turingHUDDelayedClearTask?.cancel()
        turingHUDDelayedClearTask = nil
        cancelTuringStoryPlacementRoomScan(
            reason: "debugRestart.\(attempt)"
        )

        TuringStoryWalkieAudioRoute.clear(
            reason: "debugRoomRescan.\(attempt)"
        )
        turingStoryWalkieInteractionController.walkieRemoved(
            reason: "debugRoomRescan.\(attempt)"
        )
        turingStoryDadFrameInteractionController.dadFrameRemoved(
            reason: "debugRoomRescan.\(attempt)"
        )
        turingDoorBundleController.reset(
            reason: "debugRoomRescan.\(attempt)"
        )
        turingRollingBenchBundleController.reset(
            reason: "debugRoomRescan.\(attempt)"
        )
        turingWindowBundleController.reset(
            reason: "debugRoomRescan.\(attempt)"
        )
        turingWalkieBundleController.reset(
            reason: "debugRoomRescan.\(attempt)"
        )
        wallPosterUIController.resetPlacement(
            reason: "debugRoomRescan.\(attempt)"
        )

        turingStoryPlacementScanCompleted = false
        turingStoryPlacementSpinResult = nil
        turingStoryScanSpinTracker.reset()
        pendingTuringPlacementScanReasons.removeAll()
        turingStoryWallLayoutCoordinator.resetForRetry()
        activeTuringDebugRescanAttempt = attempt

        print("""
        [TuringRoomScanDebug] repeat started
          attempt: \(attempt)
          reason: \(reason)
          previousDoorPlaced: \(previousDoorPlaced)
          previousRollingBenchPlaced: \(previousRollingBenchPlaced)
          previousWindowPlaced: \(previousWindowPlaced)
          previousWalkiePlaced: \(previousWalkiePlaced)
          previousPosterPlaced: \(previousPosterPlaced)
          retainedWallCandidates: \(roomSkinningCoordinator.wallManager.wallCandidates.count)
          retainedFloorCandidates: \(roomSkinningCoordinator.wallManager.floorCandidates.count)
          priorStoryOccupanciesRemoved: true
        """)

        requestTuringStoryPlacementRoomScan(
            reason: "debugRepeat.\(attempt).\(reason)"
        )
    }

    private func finishTuringDebugRescanIfNeeded(
        scanID: String,
        outcome: String
    ) {
        guard let attempt = activeTuringDebugRescanAttempt else {
            return
        }

        activeTuringDebugRescanAttempt = nil
        print("""
        [TuringRoomScanDebug] repeat finished
          attempt: \(attempt)
          scanID: \(scanID)
          outcome: \(outcome)
          doorPlaced: \(turingDoorBundleController.isPlaced)
          rollingBenchPlaced: \(turingRollingBenchBundleController.isPlaced)
          windowPlaced: \(turingWindowBundleController.isPlaced)
          walkiePlaced: \(turingWalkieBundleController.isPlaced)
          posterPlaced: \(wallPosterUIController.isLocked)
        """)
    }

    private func startPendingTuringDebugRescanIfNeeded(
        trigger: String
    ) {
        guard let reason = pendingTuringDebugRescanReason else {
            return
        }

        pendingTuringDebugRescanReason = nil
        print("""
        [TuringRoomScanDebug] queued repeat released
          trigger: \(trigger)
          reason: \(reason)
        """)
        restartTuringStoryPlacementRoomScan(
            reason: reason
        )
    }

    private func requestTuringStoryPlacementRoomScan(
        reason: String
    ) {
        if turingStoryPropsArePlaced {
            clearTuringPlacementHUDIfAllPropsPlaced(
                reason: "alreadyPlaced.\(reason)"
            )
            print(
                """
                [TuringRoomScan] placement scan request skipped
                  reason: \(reason)
                  existingPlacement: complete
                  action: reuse_existing_story_props
                """
            )
            return
        }

        if turingStoryPlacementScanCompleted {
            print(
                """
                [TuringRoomScan] placement scan request reused cached scan
                  reason: \(reason)
                  existingPlacement: partial
                  action: retry_missing_story_props_without_rescan
                """
            )
            turingStoryWallLayoutCoordinator.resetForRetry()
            requestTuringStoryGlobalWallLayout(
                reason: "cachedPlacementScan.\(reason)"
            )
            return
        }

        if hordeWaitingForRoomScan {
            print(
                """
                [TuringRoomScan] placement scan request ignored
                  reason: \(reason)
                  activeHordeRoomScan: true
                """
            )
            return
        }

        if turingWaitingForPlacementRoomScan {
            if !pendingTuringPlacementScanReasons.contains(reason) {
                pendingTuringPlacementScanReasons.append(reason)
            }

            print(
                """
                [TuringRoomScan] placement scan request coalesced
                  reason: \(reason)
                  pendingReasons: \(pendingTuringPlacementScanReasons.joined(separator: ","))
                """
            )
            return
        }

        pendingTuringPlacementScanReasons = [reason]
        turingWaitingForPlacementRoomScan = true
        turingWaitingForPlacementFloorPromptShown = false
        turingPlacementRoomScanTracker.begin()
        turingStoryScanSpinTracker.begin(
            headForward: spatialProvider.currentPoseOrFallback().headForward
        )
        roomSkinningCoordinator.startHordeRoomScanOnly()

        showInstructionHUD(
            "Spin around in a full 360 degree circle to place the room props."
        )

        print(
            """
            [TuringRoomScan] placement scan started
              reason: \(reason)
              usesHordeRoomScan: true
              waitsForFloor: true
            """
        )
    }

    private func updateTuringStoryPlacementRoomScanIfNeeded(
        currentPose: PhaseOneSpawnPose
    ) {
        guard turingWaitingForPlacementRoomScan else {
            return
        }

        turingPlacementRoomScanTracker.updateHeadForward(
            currentPose.headForward
        )
        turingStoryScanSpinTracker.update(
            headForward: currentPose.headForward
        )

        let percent = Int(turingPlacementRoomScanTracker.progress * 100)

        if percent >= 50,
           !turingPlacementRoomScanTracker.isComplete {
            showInstructionHUD(
                "Keep turning. Prop placement is still mapping the room. \(percent)%"
            )
        } else if !turingPlacementRoomScanTracker.isComplete {
            showInstructionHUD(
                "Spin around in a full 360 degree circle to place the room props. \(percent)%"
            )
        }

        if turingPlacementRoomScanTracker.isComplete {
            finishTuringStoryPlacementRoomScanAndPlaceProps()
        }
    }

    private func finishTuringStoryPlacementRoomScanAndPlaceProps() {
        guard turingWaitingForPlacementRoomScan else {
            return
        }

        guard roomSkinningCoordinator.wallManager.floorCandidates.values
            .contains(where: { $0.isUsableFloor }) else {
            showInstructionHUD(
                "Look down briefly. I need the floor before placing the room props."
            )

            if !turingWaitingForPlacementFloorPromptShown {
                turingWaitingForPlacementFloorPromptShown = true

                print(
                    """
                    [TuringRoomScan] scan has walls but no verified floor
                      action: waiting_for_floor
                    """
                )
            }

            return
        }

        installHordeRoomGroundingReceivers(
            reason: "turing_story_room_scan_floor_verified"
        )

        let reasons = pendingTuringPlacementScanReasons.joined(
            separator: ","
        )

        do {
            turingStoryPlacementSpinResult = try turingStoryScanSpinTracker.finish()
        } catch {
            print("[TuringWallSlices] scan spin capture failed error=\(error.localizedDescription)")
            showTemporaryInstructionHUD(
                "Prop placement needs another room scan.",
                clearAfterSeconds: 5.0,
                reason: "sliceSpinCaptureFailed"
            )
            turingWaitingForPlacementRoomScan = false
            pendingTuringPlacementScanReasons.removeAll()
            return
        }
        if let spin = turingStoryPlacementSpinResult {
            print(
                "[TuringWallSlices] scan spin captured startYawRadians=\(spin.startYawRadians) accumulatedYawRadians=\(spin.accumulatedYawRadians) direction=\(spin.direction.rawValue)"
            )
        }

        turingWaitingForPlacementRoomScan = false
        turingWaitingForPlacementFloorPromptShown = false
        turingStoryPlacementScanCompleted = true
        pendingTuringPlacementScanReasons.removeAll()

        showTemporaryInstructionHUD(
            "Room mapped. Placing props.",
            clearAfterSeconds: 2.0,
            reason: "turingPlacementScanComplete"
        )

        print(
            """
            [TuringRoomScan] placement scan complete
              reasons: \(reasons)
              floorVerified: true
              placingRollingBenchBundle: true
              placingWalkieBundle: true
              placingWindowBundle: true
              placingDoorBundle: true
            """
        )

        requestTuringStoryGlobalWallLayout(
            reason: "turingRoomScanComplete.\(reasons)"
        )
    }

    private func cancelTuringStoryPlacementRoomScan(
        reason: String
    ) {
        guard turingWaitingForPlacementRoomScan
                || !pendingTuringPlacementScanReasons.isEmpty else {
            return
        }

        turingWaitingForPlacementRoomScan = false
        turingWaitingForPlacementFloorPromptShown = false
        pendingTuringPlacementScanReasons.removeAll()
        turingPlacementRoomScanTracker.cancel()
        turingStoryScanSpinTracker.reset()

        print(
            """
            [TuringRoomScan] placement scan cancelled
              reason: \(reason)
            """
        )
    }

    private var turingStoryPropsArePlaced: Bool {
        turingStoryWallLayoutCoordinator.state == .complete &&
            turingWalkieBundleController.isPlaced &&
            turingWindowBundleController.isPlaced &&
            turingDoorBundleController.isPlaced &&
            turingRollingBenchBundleController.isPlaced &&
            wallPosterUIController.isLocked
    }

    private func requestTuringStoryGlobalWallLayout(
        reason: String
    ) {
        guard let spin = turingStoryPlacementSpinResult else {
            print("[TuringWallSlices] layout request ignored reason=missingFrozenSpin")
            return
        }
        let pose = spatialProvider.currentPoseOrFallback()
        roomSkinningCoordinator.wallManager.updateViewerPositionForWallSelection(
            pose.headPosition
        )
        turingStoryWallLayoutCoordinator.planAndCommit(
            wallManager: roomSkinningCoordinator.wallManager,
            occupancyRegistry: wallPropOccupancyRegistry,
            viewerPosition: pose.headPosition,
            viewerForward: pose.headForward,
            spin: spin,
            atmosphere: currentStoryWindowAtmosphere,
            reason: reason
        )
    }

    private func clearTuringPlacementHUDIfAllPropsPlaced(
        reason: String
    ) {
        guard turingStoryPropsArePlaced else {
            return
        }

        turingHUDDelayedClearTask?.cancel()
        turingHUDDelayedClearTask = nil
        instructionHUD.clear()

        print(
            """
            [TuringRoomScan] placement HUD cleared
              reason: \(reason)
              walkiePlaced: true
              windowPlaced: true
              doorPlaced: true
              rollingBenchPlaced: true
            """
        )
    }

    func toggleTuringStoryDoor(
        reason: String
    ) {
        turingDoorBundleController.toggleDoor(reason: reason)
    }

    func handleTuringRollingBenchAction(
        _ action: TuringRollingBenchDeviceActionComponent,
        source: String
    ) {
        switch (action.deviceID, action.action) {
        case (.hamReceiver, _), (.microphone, _):
            print(
                "[TuringRollingBench] future device action ignored deviceID=\(action.deviceID.rawValue) action=\(action.action.rawValue) source=\(source)"
            )
        case (.crankRadio, _):
            print(
                "[TuringRollingBench] legacy crank-radio action ignored action=\(action.action.rawValue) source=\(source)"
            )
        }
    }

    func configureTuringWalkieInteractionEventSink(
        _ eventSink:
            (any TuringStoryWalkieInteractionEventSink)?
    ) {
        turingStoryWalkieInteractionController
            .setEventSink(eventSink)
        turingStoryDadFrameInteractionController
            .setEventSink(eventSink)
        turingRollingBenchBundleController
            .crankRadioInteractionController
            .setEventSink(eventSink)
        turingRollingBenchBundleController
            .hamReceiverInteractionController
            .setEventSink(eventSink)
    }

    func turingWalkiePlayTapped(source: String) {
        turingStoryWalkieInteractionController
            .playTapped(source: source)
    }

    func turingWalkieMicrophoneHoldBegan(
        source: String
    ) {
        turingStoryWalkieInteractionController
            .microphoneHoldBegan(source: source)
    }

    func turingWalkieMicrophoneHoldEnded(
        source: String
    ) {
        turingStoryWalkieInteractionController
            .microphoneHoldEnded(source: source)
    }

    func turingDadFramePlayTapped(source: String) {
        turingStoryDadFrameInteractionController
            .playTapped(source: source)
    }

    func turingDadFrameMicrophoneHoldBegan(
        source: String
    ) {
        turingStoryDadFrameInteractionController
            .microphoneHoldBegan(source: source)
    }

    func turingDadFrameMicrophoneHoldEnded(
        source: String
    ) {
        turingStoryDadFrameInteractionController
            .microphoneHoldEnded(source: source)
    }

    func turingCrankRadioPlayTapped(
        source: String
    ) {
        turingRollingBenchBundleController
            .crankRadioInteractionController
            .playTapped(source: source)
    }

    func turingCrankRadioMicrophoneHoldBegan(
        source: String
    ) {
        turingRollingBenchBundleController
            .crankRadioInteractionController
            .microphoneHoldBegan(source: source)
    }

    func turingCrankRadioMicrophoneHoldEnded(
        source: String
    ) {
        turingRollingBenchBundleController
            .crankRadioInteractionController
            .microphoneHoldEnded(source: source)
    }

    func turingHamReceiverPlayTapped(
        source: String
    ) {
        turingRollingBenchBundleController
            .hamReceiverInteractionController
            .playTapped(source: source)
    }

    func turingHamReceiverMicrophoneHoldBegan(
        source: String
    ) {
        turingRollingBenchBundleController
            .hamReceiverInteractionController
            .microphoneHoldBegan(source: source)
    }

    func turingHamReceiverMicrophoneHoldEnded(
        source: String
    ) {
        turingRollingBenchBundleController
            .hamReceiverInteractionController
            .microphoneHoldEnded(source: source)
    }

    func establishedLayoutFingerprint() throws -> TuringStoryEstablishedLayoutFingerprint {
        guard turingStoryPropsArePlaced else {
            throw TuringStoryContinuationError.storyStageNotEstablished
        }
        return TuringStoryEstablishedLayoutFingerprint(
            doorWorldTransform: turingDoorBundleController.root.transformMatrix(relativeTo: nil),
            windowWorldTransform: turingWindowBundleController.root.transformMatrix(relativeTo: nil),
            walkieShelfWorldTransform: turingWalkieBundleController.root.transformMatrix(relativeTo: nil),
            rollingBenchWorldTransform: turingRollingBenchBundleController.root.transformMatrix(relativeTo: nil),
            posterWorldTransform: wallPosterUIController.root.transformMatrix(relativeTo: nil),
            canonicalWallIDs: roomSkinningCoordinator.wallManager.wallCandidates.keys
                .sorted { $0.uuidString < $1.uuidString },
            occupancyIDs: wallPropOccupancyRegistry.recordsByID.keys
                .sorted { $0.uuidString < $1.uuidString }
        )
    }

    func quiesceStoryRuntime(teleportID: UUID) async throws {
        let reason = "storyTeleport.\(teleportID.uuidString)"
        if MindEyeQualificationFeatureControl.isMindEyeEnabled {
            _ = await mindEyeRuntimeLifecycle.resetForStoryBoundary(
                scope: .storyTeleport,
                reason: reason
            )
        }
        await turingStoryWalkieInteractionController.quiesceForStoryTeleport(reason: reason)
        await TuringEpisodeFlowController.shared.quiesceForStoryTeleport(reason: reason)
        battle01Coordinator?.cancel(reason: reason)
        await chapter01Coordinator?.cancel(reason: reason)
        await chapter02Coordinator?.cancel(reason: reason)
        await chapter03Coordinator?.cancel(reason: reason)
        prologueCompletionCoordinator?.reset(reason: reason)
        print("""
        [TuringStoryTeleport] transient runtime quiesced
          teleportID: \(teleportID.uuidString)
          placementReset: false
          crankRadioPreserved: true
        """)
    }

    func prepareEpisodeInteractionBindings(
        _ episodeID: TuringEpisodeID,
        teleportID: UUID
    ) {
        guard episodeID == .prologue else {
            return
        }

        let reason = "storyTeleport.\(teleportID.uuidString).prologueBindings"
        turingStoryWalkieInteractionController.episodeStarted(.prologue)
        turingStoryDadFrameInteractionController.stageBinding(
            .prologueDadPhoto,
            reason: reason
        )
        turingRollingBenchBundleController.hamReceiverInteractionController
            .stageBinding(
                .prologueHamReceiver,
                reason: reason
            )
        TuringFlowInteractionGateController.shared.applyStableState(
            .closed,
            surfaceID: .dadFrame,
            reason: reason
        )
        TuringFlowInteractionGateController.shared.applyStableState(
            .closed,
            surfaceID: .crankRadio,
            reason: reason
        )
        TuringFlowInteractionGateController.shared.applyStableState(
            .closed,
            surfaceID: .hamReceiver,
            reason: reason
        )
        print("""
        [TuringStoryTeleport] episode interaction bindings prepared
          teleportID: \(teleportID.uuidString)
          episodeID: \(episodeID.rawValue)
          walkieConversationKey: \(TuringStorySurfaceFlowBinding.prologueWalkie.conversationKey)
          dadFrameConversationKey: \(TuringStorySurfaceFlowBinding.prologueDadPhoto.conversationKey)
          hamReceiverConversationKey: \(TuringStorySurfaceFlowBinding.prologueHamReceiver.conversationKey)
        """)
    }

    func applyDoorDestination(
        _ destination: TuringStoryDoorDestination?,
        teleportID: UUID
    ) async throws {
        guard let destination else { return }
        turingDoorBundleController.setDoorStateImmediatelyForStoryTeleport(
            destination,
            teleportID: teleportID
        )
    }

    func applyBattleDestination(
        _ destination: TuringStoryBattleDestination,
        teleportID: UUID,
        storyTransitionLease: StoryInteractionLease?
    ) async throws {
        switch destination {
        case .absent:
            battle01Coordinator?.cancel(reason: "storyTeleport.absent.\(teleportID.uuidString)")
            await chapter01Coordinator?.cancel(
                reason: "storyTeleport.absent.\(teleportID.uuidString)"
            )
            await chapter02Coordinator?.cancel(
                reason: "storyTeleport.absent.\(teleportID.uuidString)"
            )
            await chapter03Coordinator?.cancel(
                reason: "storyTeleport.absent.\(teleportID.uuidString)"
            )
            prologueStoryActionRouter?.reset(reason: "storyTeleport.absent")
        case .battle01Start:
            guard let storyTransitionLease else {
                throw StoryInteractionClaimError.invalidTransfer
            }
            let sourceEventID = TuringStoryProgressStore.shared.snapshot?.sourceEventID ?? UUID()
            try await prologueStoryActionRouter?.startBattle01FromContinuation(
                sourceEventID: sourceEventID,
                storyTransitionLease: storyTransitionLease
            )
        case .battle01Ready, .battle01Combat, .battle01GrandmaDown:
            throw TuringStoryContinuationError.unsupportedEpisode
        }
    }

    func applyMediaDestination(
        _ destination: TuringStoryMediaDestination,
        teleportID: UUID
    ) async throws {
        // Battle media is owned by Battle01 and was either stopped by quiesce
        // or started by the typed battle destination. The crank radio is not touched.
        print("[TuringStoryTeleport] media destination=\(destination) teleportID=\(teleportID.uuidString)")
    }

    func applyWalkieDestination(
        _ destination: TuringStoryWalkieDestination,
        teleportID: UUID
    ) async throws {
        let reason = "storyTeleport.\(teleportID.uuidString)"
        switch destination {
        case .play(let scriptPointID, _):
            StoryModeActionCoordinator.shared.activate(
                .init(
                    episodeID: .prologue,
                    rootScriptPointID: scriptPointID,
                    durableBoundaryID:
                        "prologue.teleport.\(teleportID.uuidString).\(scriptPointID)",
                    sourceEventID: teleportID
                )
            )
        case .microphone:
            turingStoryWalkieInteractionController.hideForStoryTeleport(reason: reason)
        case .hidden:
            turingStoryWalkieInteractionController.hideForStoryTeleport(reason: reason)
        }
    }

    @MainActor
    private func configureTuringWalkieAudioAndInteraction(
        reason: String,
        attempt: Int
    ) {
        guard let walkieEmitter = turingWalkieBundleController.walkieAudioEmitter else {
            print("""
            [TuringAudio] ERROR cannot select walkie emitter
              reason: missing_walkie_emitter
              source: turing_story_wall_bundle_v1
            """)
            return
        }

        TuringStoryWalkieAudioRoute.install(
            audioController: audioController,
            walkieEmitter: walkieEmitter
        )

        if let iconAnchor =
                turingWalkieBundleController.walkieIconAnchor,
           let walkieRoot =
                turingWalkieBundleController.walkieRoot {
            turingStoryWalkieInteractionController
                .walkieInstalled(
                    iconAnchor: iconAnchor,
                    walkieRoot: walkieRoot
                )
        } else {
            print("""
            [TuringWalkieState] ERROR action targets unavailable
              iconAnchor: \(turingWalkieBundleController.walkieIconAnchor?.name ?? "nil")
              walkieRoot: \(turingWalkieBundleController.walkieRoot?.name ?? "nil")
            """)
        }

        if let iconAnchor =
                turingWalkieBundleController.dadFrameIconAnchor,
           let dadFrameRoot =
                turingWalkieBundleController.dadFrameRoot {
            turingStoryDadFrameInteractionController
                .dadFrameInstalled(
                    iconAnchor: iconAnchor,
                    dadFrameRoot: dadFrameRoot
                )
            turingStoryDadFrameInteractionController.bind(
                .prologueDadPhoto,
                initialState: .closed,
                reason: "dadFrameInstalledClosed"
            )
        } else {
            print("""
            [TuringDadFrame] ERROR action targets unavailable
              iconAnchor: \(turingWalkieBundleController.dadFrameIconAnchor?.name ?? "nil")
              dadFrameRoot: \(turingWalkieBundleController.dadFrameRoot?.name ?? "nil")
            """)
        }

        print("""
        [TuringScriptTrigger] physical anchors registered
          walkieTalkie: \(turingWalkieBundleController.walkieIconAnchor?.name ?? "nil")
          dadFrame: \(turingWalkieBundleController.dadFrameIconAnchor?.name ?? "nil")
          reason: \(reason)
          placementAttempt: \(attempt)
        """)
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
            "horde.portal_mirror.retained.count",
            retainedPortalMirrorControllersByEnemyID.count
        )
        timingProfiler.setCounter(
            "portal_mirror.active_ingress.count",
            activeIngressControllers.count
        )
        timingProfiler.setCounter(
            "portal_mirror.retained.count",
            retainedPortalMirrorControllersByEnemyID.count
        )
        timingProfiler.setCounter(
            "portal_mirror.retention_cutoff_wave",
            HordePortalMirrorOptimizationSettings.retainMirrorsThroughWave
        )
        let destroysAfterExitForCurrentWave =
            HordePortalMirrorOptimizationSettings.retentionPolicy(
                forWave: hordeCurrentWave
            ) == .destroyAfterExit
        timingProfiler.setCounter(
            "portal_mirror.destroy_after_exit_enabled",
            destroysAfterExitForCurrentWave ? 1 : 0
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
                case .applyFollowIntent(let id, _),
                     .enterCloseRangeReady(let id, _, _),
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

    private func submitHordeBrainIfIdle(
        now: TimeInterval,
        force: Bool = false
    ) {
        guard hordeBenchmarkRunning,
              !hordeBrainInFlight else {
            return
        }

        let elapsed = now - lastHordeBrainSubmitTime
        let shouldSubmit =
            force ||
            forceNextHordeBrainSubmit ||
            elapsed >= HordeEnemyBrainSettings.decisionIntervalSeconds

        guard shouldSubmit,
              let frame = latestFrameClockSnapshot,
              let player = latestPlayerPoseSnapshot else {
            return
        }

        let enemyBrains = latestEnemyBrainSnapshots

        guard !enemyBrains.isEmpty else {
            return
        }

        let bodyObstacles = latestEnemyBodySnapshots
        let request = EnemyBrainBatchRequest(
            frame: frame,
            player: player,
            enemies: enemyBrains,
            bodyObstacles: bodyObstacles
        )

        forceNextHordeBrainSubmit = false
        lastHordeBrainSubmitTime = now
        hordeBrainInFlight = true

        let engine = hordeEnemyBrainEngine

        hordeBrainTask = Task { [weak self] in
            let commands = await engine.step(request)

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
        lastHordeBrainSubmitTime = 0
        forceNextHordeBrainSubmit = false

        let simulationEngine = hordeSimulationEngine
        let brainEngine = hordeEnemyBrainEngine

        Task {
            await simulationEngine.reset()
            await brainEngine.reset()
        }
    }

    func startChapter01RobotEncounter(
        chapterRunID: UUID,
        storyTransitionLease: StoryInteractionLease,
        completionSink: any Chapter01RobotEncounterCompletionSink
    ) async throws {
        guard let chapter01RobotEncounterCoordinator else {
            throw Chapter01RobotError.invalidEncounterState(
                "immersive Robot coordinator is not installed"
            )
        }
        try await chapter01RobotEncounterCoordinator.validateAvailability()
        let battleLease = try await StoryInteractionArbiter.shared
            .transferStoryTransitionToBattle(
                storyTransitionLease: storyTransitionLease,
                battleInstanceID: chapterRunID,
                reason: "dadWindowAuthoredMidpointReached"
            )
        do {
            try await chapter01RobotEncounterCoordinator.start(
                request: Chapter01RobotEncounterRequest(
                    chapterRunID: chapterRunID,
                    battleLease: battleLease,
                    completionSink: completionSink
                )
            )
        } catch {
            if case .storyTransition(let transitionID) = storyTransitionLease.owner {
                _ = try? await StoryInteractionArbiter.shared
                    .transferBattleToStoryTransition(
                        battleLease: battleLease,
                        transitionID: transitionID,
                        reason: "chapter01RobotStartFailed"
                    )
            } else {
                await StoryInteractionArbiter.shared.release(
                    battleLease,
                    reason: "chapter01RobotStartFailed"
                )
            }
            throw error
        }
    }

    func chapter01DadCenteredInWindow(chapterRunID: UUID) async throws {
        let music = Chapter01MusicController.shared
        try await music.prepare(catalog: Chapter01MusicCatalog.load())
        try await music.play(.dadWindow, chapterRunID: chapterRunID)
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

        battle01Coordinator?.update(
            deltaTime: TimeInterval(deltaTime),
            playerTargetWorldPosition: currentHeadPosition
        )
        chapter01RobotEncounterCoordinator?.update(
            deltaTime: TimeInterval(deltaTime)
        )
        chapter01Coordinator?.update(
            deltaTime: TimeInterval(deltaTime),
            playerTargetWorldPosition: currentHeadPosition
        )
        chapter02Coordinator?.update(
            deltaTime: TimeInterval(deltaTime),
            playerTargetWorldPosition: currentHeadPosition
        )
        chapter03Coordinator?.update(
            deltaTime: TimeInterval(deltaTime),
            playerTargetWorldPosition: currentHeadPosition
        )

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

            updateTuringStoryPlacementRoomScanIfNeeded(
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

            timingProfiler.measure("portal_mirror.visibility_update") {
                syncAllPortalMirrorsAfterEnemyAnimations()
            }

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
                submitHordeBrainIfIdle(
                    now: CACurrentMediaTime()
                )
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

    func shutdown() async {
        await TuringQwenNativeRecoveryCoordinator.shared.shutdown()
        if MindEyeQualificationFeatureControl.isMindEyeEnabled {
            _ = await mindEyeRuntimeLifecycle.shutdown(reason: "immersiveShutdown")
            await TuringHighMemoryPreflightCoordinator.shared.clearMindEye()
        }
        operationModeSwitchGeneration += 1
        operationModeSwitchTask?.cancel()
        operationModeSwitchTask = nil
        storyAmbientGunfireLifecycle?.shutdown(reason: "immersiveShutdown")
        storyAmbientGunfireWorldBridge.unbind(reason: "immersiveShutdown")
        storyAmbientCountyLifecycle?.shutdown(reason: "immersiveShutdown")
        storyAmbientCountyWorldBridge.unbind(reason: "immersiveShutdown")
        storyAmbientCountySecondaryLifecycle?.shutdown(
            reason: "immersiveShutdown"
        )
        storyAmbientCountySecondaryWorldBridge.unbind(
            reason: "immersiveShutdown"
        )
        storyAmbientAircraftLifecycle?.shutdown(reason: "immersiveShutdown")
        storyAmbientAircraftWorldBridge.unbind(reason: "immersiveShutdown")
        storyTitleCardTransitionCoordinator.reset(reason: "immersiveShutdown")
        StoryModeActionCoordinator.shared.reset(reason: "immersiveShutdown")
        StoryInteractionPresentationCoordinator.shared.stop()
        TuringStoryStateTeleportCoordinator.shared.detach(self)
        TuringStoryStageCoordinator.shared.invalidate(reason: "immersiveShutdown")
        battle01Coordinator?.cancel(reason: "immersiveShutdown")
        battle01Coordinator = nil
        let chapter01Robot = chapter01RobotEncounterCoordinator
        let chapter01 = chapter01Coordinator
        let chapter01DadBattle = chapter01DadFinalBattleCoordinator
        let chapter02 = chapter02Coordinator
        chapter01RobotEncounterCoordinator = nil
        chapter01DadWindowCoordinator = nil
        chapter01DadFinalBattleCoordinator = nil
        chapter01Coordinator = nil
        chapter02WindowWomanCoordinator = nil
        chapter02WomanBattleCoordinator = nil
        chapter02Coordinator = nil
        let chapter03 = chapter03Coordinator
        chapter03Coordinator = nil
        storyCompletionRouter = nil
        prologueStoryActionRouter = nil
        prologueCompletionCoordinator = nil
        turingHighMemoryPreflightAdapter = nil
        Task {
            await chapter01?.cancel(reason: "immersiveShutdown")
            await chapter01DadBattle?.cancel(reason: "immersiveShutdown")
            await chapter01Robot?.cancel(reason: "immersiveShutdown")
            await chapter02?.cancel(reason: "immersiveShutdown")
            await TuringHighMemoryPreflightCoordinator.shared.clear()
            await TuringEpisodeFlowController.shared
                .setCompletionEventSink(nil)
            await StoryInteractionArbiter.shared.reset(
                reason: "immersiveShutdown"
            )
        }
        turingStoryPlacementAdjustmentCoordinator.cancel(
            reason: "immersiveShutdown"
        )
        onYouDiedWorldCardCleanupRequested?()
        stopHordeBenchmark()
        turingStoryWallLayoutCoordinator.cancel(reason: "immersiveShutdown")
        roomSkinningCoordinator.cancelRoomSkinning()
        turingStoryPlacementScanCompleted = false
        turingStoryPlacementSpinResult = nil
        turingStoryScanSpinTracker.reset()
        jockRetargetController?.hide()
        spatialProvider.onPlaneAnchorUpdate = nil
        spatialProvider.stop()
        audioController.stopAllAudio()
        resetHordeBenchmarkDeathPresentation()
        forestEnvironmentController.shutdown()
        wallPosterUIController.reset()
        turingStoryWalkieInteractionController.walkieRemoved(
            reason: "immersiveShutdown"
        )
        turingStoryDadFrameInteractionController.dadFrameRemoved(
            reason: "immersiveShutdown"
        )
        turingWalkieBundleController.reset(reason: "immersiveShutdown")
        turingWindowBundleController.reset(reason: "immersiveShutdown")
        turingDoorBundleController.reset(reason: "immersiveShutdown")
        turingRollingBenchBundleController.unload(reason: "immersiveShutdown")
        HDRIDomePortalContentProvider.clearSharedResourceCache(
            reason: "immersiveShutdown"
        )
        Task { @MainActor in
            await chapter03?.cancel(reason: "immersiveShutdown")
            await turingStoryWalkieInteractionController.shutdown(
                reason: "immersiveShutdown"
            )
            await turingStoryDadFrameInteractionController.shutdown(
                reason: "immersiveShutdown"
            )
            await turingRollingBenchBundleController
                .crankRadioInteractionController
                .shutdown(
                    reason: "immersiveShutdown"
                )
            await turingRollingBenchBundleController
                .hamReceiverInteractionController
                .shutdown(
                    reason: "immersiveShutdown"
                )
            await TuringFlowMediaCueCoordinator.shared.stopAll(
                reason: "immersiveShutdown"
            )
            TuringStoryWalkieAudioRoute.clear(reason: "immersiveShutdown")
            TuringRichHeadsetAudioRoute.clear(reason: "immersiveShutdown")
        }
        onWallPosterUIActiveChanged?(false)

        storyAmbientGunfireLifecycle = nil
        storyAmbientCountyLifecycle = nil
        storyAmbientCountySecondaryLifecycle = nil
        storyAmbientAircraftLifecycle = nil
        sceneRoot = nil
        headAnchor = nil
        jockRetargetController = nil
        lastWallPosterPlacementAttempt = nil
        lastTickDate = nil
        handledCommandIDs.removeAll()
        pendingCommands.removeAll()
        #if GR_MIND_EYE_QUALIFICATION
        await MindEyeReleaseQualificationHooks.shared.finishAfterShutdown()
        #endif
    }

    func mindEyeApplicationStateChanged(
        _ state: MindEyeApplicationLifecycleState
    ) async {
        if MindEyeQualificationFeatureControl.isMindEyeEnabled {
            await mindEyeRuntimeLifecycle.applicationStateChanged(
                to: state,
                reason: "immersiveScenePhase"
            )
        }
    }

    private func prepareForUserQuitOrClose() {
        operationModeSwitchGeneration += 1
        operationModeSwitchTask?.cancel()
        operationModeSwitchTask = nil
        battle01Coordinator?.cancel(reason: "userQuitOrClose")
        Task { @MainActor [weak self] in
            await self?.chapter01Coordinator?.cancel(
                reason: "userQuitOrClose"
            )
            await self?.chapter02Coordinator?.cancel(
                reason: "userQuitOrClose"
            )
            await self?.chapter03Coordinator?.cancel(
                reason: "userQuitOrClose"
            )
        }
        turingStoryPlacementAdjustmentCoordinator.cancel(
            reason: "userQuitOrClose"
        )
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
        turingStoryWallLayoutCoordinator.cancel(reason: "prepareForUserQuitOrClose")
        cancelTuringStoryPlacementRoomScan(
            reason: "prepareForUserQuitOrClose"
        )
        turingStoryPlacementScanCompleted = false
        turingStoryPlacementSpinResult = nil
        turingStoryScanSpinTracker.reset()
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
        battle01Coordinator?.cancel(reason: "modeSwitchToHorde")
        Task { @MainActor [weak self] in
            await self?.chapter01Coordinator?.cancel(
                reason: "modeSwitchToHorde"
            )
            await self?.chapter02Coordinator?.cancel(
                reason: "modeSwitchToHorde"
            )
            await self?.chapter03Coordinator?.cancel(
                reason: "modeSwitchToHorde"
            )
        }
        guard !hordeWaitingForRoomScan else {
            print("[HordeRoomScan] Horde start ignored; scan already active")
            return
        }

        cancelTuringStoryPlacementRoomScan(
            reason: "horde_room_scan_started"
        )
        hordeRoomScanCompletionTask?.cancel()
        hordeRoomScanCompletionTask = nil
        pendingNextBenchmarkWaveTask?.cancel()
        pendingNextBenchmarkWaveTask = nil
        resetHordeDeathReplacementRuntime(
            reason: "horde_room_scan_started"
        )
        clearHordeEnemyControllers()
        cleanupAllPortalMirrors(
            reason: "horde_room_scan_started"
        )
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

        installHordeRoomGroundingReceivers(
            reason: "horde_room_scan_floor_verified"
        )

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

    private func clearInstructionHUDForPlayerDeath() {
        turingHUDDelayedClearTask?.cancel()
        turingHUDDelayedClearTask = nil
        instructionHUD.clear()
        print("[PlagueHUD] instruction HUD suppressed for player death")
    }

    private func showTemporaryInstructionHUD(
        _ text: String,
        clearAfterSeconds: Double,
        reason: String
    ) {
        turingHUDDelayedClearTask?.cancel()
        showInstructionHUD(text)

        let delayNanoseconds = UInt64(
            max(0, clearAfterSeconds) * 1_000_000_000
        )

        turingHUDDelayedClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else {
                return
            }

            self?.instructionHUD.clear()
            self?.turingHUDDelayedClearTask = nil

            print(
                """
                [PlagueHUD] temporary instruction HUD cleared
                  reason: \(reason)
                  text: \(text)
                """
            )
        }
    }

    private func installHordeRoomGroundingReceivers(
        reason: String
    ) {
        HordeGroundingOcclusionInstaller.installRoomReceivers(
            on: roomSkinningCoordinator.root,
            reason: reason
        )
    }

    private func updatePortalIngressControllers(
        deltaTime: Float,
        playerWorldPosition: SIMD3<Float>
    ) {
        var finishedIDs: [UUID] = []
        var retainedIDs: [UUID] = []
        var destroyedAfterExitIDs: [UUID] = []
        var failedIDs: [UUID] = []

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
                forceNextHordeBrainSubmit = true

                if ingress.shouldRetainPortalMirrorAfterExit {
                    retainedIDs.append(enemyID)

                    print(
                        """
                        [HordePortalMirror] retained after ingress exit
                          enemyID: \(enemyID)
                          policy: \(ingress.portalMirrorRetentionPolicyName)
                          retainedFallback: true
                        """
                    )
                } else {
                    retainedPortalMirrorControllersByEnemyID.removeValue(
                        forKey: enemyID
                    )

                    ingress.cleanupPortalMirror(
                        reason: "mirror_destroyed_after_ingress_wave_cap"
                    )

                    destroyedAfterExitIDs.append(enemyID)

                    print(
                        """
                        [HordePortalMirror] destroyed after ingress exit
                          enemyID: \(enemyID)
                          policy: \(ingress.portalMirrorRetentionPolicyName)
                          reason: high_wave_memory_cap
                          gameplayEnemyStillAlive: true
                          retainedFallback: false
                        """
                    )
                }

                finishedIDs.append(enemyID)

            case .failed:
                failedIDs.append(enemyID)
                finishedIDs.append(enemyID)

            case .walkingParallelInsidePortal,
                 .turningTowardExit,
                 .crossingAperture:
                break
            }
        }

        for enemyID in retainedIDs {
            guard let ingress = activeIngressControllers[enemyID] else {
                continue
            }

            guard ingress.shouldRetainPortalMirrorAfterExit else {
                assertionFailure(
                    "A destroy-after-exit portal mirror reached the retained transfer path."
                )

                ingress.cleanupPortalMirror(
                    reason: "destroy_policy_rejected_from_retained_transfer"
                )

                retainedPortalMirrorControllersByEnemyID.removeValue(
                    forKey: enemyID
                )

                continue
            }

            guard ingress.portalMirrorRetainedAfterExit else {
                continue
            }

            retainedPortalMirrorControllersByEnemyID[enemyID] = ingress
        }

        for enemyID in failedIDs {
            activeIngressControllers[enemyID]?.cleanupPortalMirror(
                reason: "portal_ingress_failed"
            )
        }

        for enemyID in finishedIDs {
            activeIngressControllers.removeValue(forKey: enemyID)
        }

        #if DEBUG
        for enemyID in destroyedAfterExitIDs {
            assert(
                activeIngressControllers[enemyID] == nil,
                "Finished high-wave ingress controller remained active."
            )

            assert(
                retainedPortalMirrorControllersByEnemyID[enemyID] == nil,
                "High-wave mirror controller was incorrectly retained."
            )
        }
        #endif
    }

    private func enforcePortalMirrorRetentionPolicy(
        forWave wave: Int
    ) {
        let policy =
            HordePortalMirrorOptimizationSettings.retentionPolicy(
                forWave: wave
            )

        guard policy == .destroyAfterExit else {
            return
        }

        guard !retainedPortalMirrorControllersByEnemyID.isEmpty else {
            return
        }

        let retainedControllers =
            retainedPortalMirrorControllersByEnemyID

        retainedPortalMirrorControllersByEnemyID.removeAll(
            keepingCapacity: false
        )

        for (enemyID, ingress) in retainedControllers {
            ingress.cleanupPortalMirror(
                reason: "retained_mirror_purged_at_wave_cutoff"
            )

            print(
                """
                [HordePortalMirror] earlier retained mirror purged
                  currentWave: \(wave)
                  enemyID: \(enemyID)
                  gameplayEnemyStillAlive: true
                  retainedFallback: false
                """
            )
        }

        print(
            """
            [HordePortalMirror] retained mirror wave cap enforced
              currentWave: \(wave)
              retainMirrorsThroughWave: \(HordePortalMirrorOptimizationSettings.retainMirrorsThroughWave)
              mirrorsPurged: \(retainedControllers.count)
            """
        )
    }

    private func syncAllPortalMirrorsAfterEnemyAnimations() {
        for ingress in activeIngressControllers.values {
            ingress.updatePortalMirrorAfterSourceAnimation()
        }

        for ingress in retainedPortalMirrorControllersByEnemyID.values {
            ingress.updatePortalMirrorAfterSourceAnimation()
        }

        let allMirrorControllers =
            Array(activeIngressControllers.values) +
            Array(retainedPortalMirrorControllersByEnemyID.values)

        let visibleCount = allMirrorControllers.filter {
            $0.portalMirrorVisibilityState == .visiblePortalSideOrCrossing
        }.count

        let hiddenRetainedCount = allMirrorControllers.filter {
            $0.portalMirrorVisibilityState == .hiddenRoomSideRetained
        }.count

        timingProfiler.setCounter(
            "portal_mirror.visible_or_crossing.count",
            visibleCount
        )
        timingProfiler.setCounter(
            "portal_mirror.hidden_retained.count",
            hiddenRetainedCount
        )
    }

    private func cleanupPortalMirror(
        enemyID: UUID,
        reason: String
    ) {
        if let ingress = activeIngressControllers.removeValue(
            forKey: enemyID
        ) {
            ingress.cleanupPortalMirror(
                reason: reason
            )
        }

        if let ingress = retainedPortalMirrorControllersByEnemyID.removeValue(
            forKey: enemyID
        ) {
            ingress.cleanupPortalMirror(
                reason: reason
            )
        }
    }

    private func retainPortalMirrorForEnemyIfNeeded(
        enemyID: UUID
    ) {
        guard let ingress = activeIngressControllers.removeValue(
            forKey: enemyID
        ) else {
            return
        }

        retainedPortalMirrorControllersByEnemyID[enemyID] = ingress
    }

    private func cleanupAllPortalMirrors(
        reason: String
    ) {
        for ingress in activeIngressControllers.values {
            ingress.cleanupPortalMirror(
                reason: reason
            )
        }

        for ingress in retainedPortalMirrorControllersByEnemyID.values {
            ingress.cleanupPortalMirror(
                reason: reason
            )
        }

        activeIngressControllers.removeAll()
        retainedPortalMirrorControllersByEnemyID.removeAll()
    }

    private func authoritativeLivingOrIngressEnemyIDs() -> Set<UUID> {
        var ids = activeHordeEnemyIDs
        ids.formUnion(activeIngressControllers.keys)

        for (id, controller) in hordeEnemyControllersByID
            where controller.hordeLifecycleState.isLivingGameplayEnemy {
            ids.insert(id)
        }

        return ids
    }

    private func authoritativeLivingOrIngressEnemyCount() -> Int {
        authoritativeLivingOrIngressEnemyIDs().count
    }

    private func assertHordeReplacementInvariants(
        context: StaticString
    ) {
        #if DEBUG
        guard let state = hordeDeathReplacementState else {
            return
        }

        assert(
            state.consumedReplacementCount >= 0,
            "\(context)"
        )
        assert(
            state.consumedReplacementCount <= state.replacementBudget,
            "Replacement budget exceeded: \(context)"
        )

        let queuedIDs = Set(
            state.queuedRequests.map(\.replacementEnemyID)
        )

        assert(
            queuedIDs.isSubset(of: state.reservedReplacementEnemyIDs),
            "Queued replacement lacks a reserved slot: \(context)"
        )

        if let inFlightID = state.inFlightRequest?.replacementEnemyID {
            assert(
                state.reservedReplacementEnemyIDs.contains(inFlightID),
                "In-flight replacement lacks a reserved slot: \(context)"
            )
        }

        assert(
            state.successfulReplacementCount + state.failedReplacementCount <=
                state.consumedReplacementCount,
            "Replacement outcome count is invalid: \(context)"
        )

        assert(
            authoritativeLivingOrIngressEnemyCount() + state.pendingReplacementCount <=
                HordeWaveRules.maxConcurrentCombatants,
            "Six-combatant capacity exceeded: \(context)"
        )
        #endif
    }

    private func resetHordeDeathReplacementRuntime(
        reason: String
    ) {
        hordeReplacementPumpTask?.cancel()
        hordeReplacementPumpTask = nil
        hordeReplacementPumpID = nil

        for task in hordeReplacementCorpseCleanupTasksByEnemyID.values {
            task.cancel()
        }
        hordeReplacementCorpseCleanupTasksByEnemyID.removeAll()

        if let state = hordeDeathReplacementState {
            print(
                """
                [HordeReplacement] runtime reset
                  reason: \(reason)
                  runID: \(state.runID)
                  generation: \(state.generation)
                  wave: \(state.wave)
                  queued: \(state.queuedRequests.count)
                  inFlight: \(state.inFlightRequest != nil)
                  reserved: \(state.pendingReplacementCount)
                  consumed: \(state.consumedReplacementCount)/\(state.replacementBudget)
                  successful: \(state.successfulReplacementCount)
                  failed: \(state.failedReplacementCount)
                """
            )
        }

        hordeDeathReplacementState = nil
    }

    private func isCurrentReplacementRequest(
        _ request: HordeDeathReplacementRequest
    ) -> Bool {
        guard !Task.isCancelled,
              hordeBenchmarkRunning,
              !isPlayerDeathSequenceActive,
              hordePortalSystemReady,
              let state = hordeDeathReplacementState else {
            return false
        }

        return state.runID == request.runID &&
            state.generation == request.waveGeneration &&
            state.wave == request.wave &&
            state.reservedReplacementEnemyIDs.contains(
                request.replacementEnemyID
            )
    }

    private func ensureHordeReplacementPumpRunning() {
        guard hordeReplacementPumpTask == nil,
              let state = hordeDeathReplacementState,
              !state.queuedRequests.isEmpty else {
            return
        }

        let pumpID = UUID()
        let runID = state.runID
        let generation = state.generation

        hordeReplacementPumpID = pumpID

        hordeReplacementPumpTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.drainHordeReplacementQueue(
                pumpID: pumpID,
                runID: runID,
                generation: generation
            )
        }
    }

    private func drainHordeReplacementQueue(
        pumpID: UUID,
        runID: UUID,
        generation: UUID
    ) async {
        while !Task.isCancelled {
            guard hordeReplacementPumpID == pumpID,
                  var state = hordeDeathReplacementState,
                  state.runID == runID,
                  state.generation == generation,
                  hordeBenchmarkRunning,
                  !isPlayerDeathSequenceActive else {
                break
            }

            guard state.inFlightRequest == nil else {
                assertionFailure("[HordeReplacement] replacement pump found existing in-flight request")
                break
            }

            guard !state.queuedRequests.isEmpty else {
                break
            }

            let request = state.queuedRequests.removeFirst()
            state.inFlightRequest = request
            hordeDeathReplacementState = state

            print(
                """
                [HordeReplacement] replacement build started
                  runID: \(request.runID)
                  generation: \(request.waveGeneration)
                  wave: \(request.wave)
                  deadEnemyID: \(request.deadEnemyID)
                  replacementEnemyID: \(request.replacementEnemyID)
                  archetype: \(request.archetype.rawValue)
                  spawnIndex: \(request.replacementSpawnIndex)
                  queueDepth: \(state.queuedRequests.count)
                  reservedCount: \(state.pendingReplacementCount)
                """
            )

            assertHordeReplacementInvariants(
                context: "drainHordeReplacementQueue_start"
            )

            await spawnDeathReplacementThroughPortal(
                request
            )

            checkWaveCanEnd(
                wave: request.wave
            )
        }

        if hordeReplacementPumpID == pumpID {
            hordeReplacementPumpTask = nil
            hordeReplacementPumpID = nil

            if let state = hordeDeathReplacementState,
               !state.queuedRequests.isEmpty {
                ensureHordeReplacementPumpRunning()
            }
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
        if turingStoryWallLayoutCoordinator.isPlanningOrCommitting {
            return
        }

        if wallPosterUIController.isLocked {
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

        forestEnvironmentController.applyIBLReceiverRecursively(
            root: wallPosterUIController.root
        )
        onWallPosterUIActiveChanged?(true)

        print(
            """
            [WallPosterUI] poster committed
              futurePlacementTicks: disabled
            """
        )
    }

    private func prepareWallPosterBeforeHordePortals(
        currentPose: PhaseOneSpawnPose
    ) -> Bool {
        if wallPosterUIController.isLocked {
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
        resetHordeDeathReplacementRuntime(
            reason: "start_horde_benchmark"
        )
        currentHordeRunID = UUID()
        clearHordeEnemyControllers()
        cleanupAllPortalMirrors(
            reason: "start_horde_benchmark"
        )
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
        resetHordeDeathReplacementRuntime(
            reason: "stop_horde_benchmark"
        )
        hordePrewarmCoordinator.releaseAll()

        hordeBenchmarkRunning = false
        hordeRuntimePhase = .idle
        hordeWaitingForRoomScan = false
        hordeWaitingForFloorPromptShown = false
        hordeRoomScanTracker.cancel()
        instructionHUD.clear()
        audioController.stopHordeMusicSequence()
        audioController.stopDemoAudio()
        cleanupAllPortalMirrors(
            reason: "stop_horde_benchmark"
        )
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
        enforcePortalMirrorRetentionPolicy(
            forWave: nextWave
        )
        resetHordeDeathReplacementRuntime(
            reason: "starting_wave_\(nextWave)"
        )

        let waveGeneration = UUID()
        let lineup = HordeWaveRules.initialLineup(
            wave: nextWave
        )
        let spawnCount = lineup.count

        hordeDeathReplacementState = HordeWaveDeathReplacementState(
            runID: currentHordeRunID,
            generation: waveGeneration,
            wave: nextWave,
            replacementBudget: HordeWaveRules.replacementBudget(
                wave: nextWave
            )
        )

        print(
            """
            [HordeReplacement] wave rules initialized
              runID: \(currentHordeRunID)
              generation: \(waveGeneration)
              wave: \(nextWave)
              initialSpawnCount: \(spawnCount)
              replacementBudget: \(HordeWaveRules.replacementBudget(wave: nextWave))
              maxConcurrentCombatants: \(HordeWaveRules.maxConcurrentCombatants)
              replacementBuildConcurrency: 1
            """
        )

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

        HordeGroundingOcclusionInstaller.installZombieCasters(
            on: controller.rootEntity,
            enemyID: id,
            characterID: controller.enemySeparationCharacterID,
            reason: "real_horde_enemy_registered"
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

            forceNextHordeBrainSubmit = true

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

        HordeGroundingOcclusionInstaller.installZombieCasters(
            on: controller.rootEntity,
            enemyID: id,
            characterID: controller.enemySeparationCharacterID,
            reason: "real_horde_enemy_registered"
        )

        do {
            let mirrorRetentionPolicy =
                HordePortalMirrorOptimizationSettings.retentionPolicy(
                    forWave: wave
                )

            let ingress = try HordePortalInstancedIngressController(
                enemy: controller,
                portal: portal,
                sceneRoot: sceneRoot,
                side: side,
                mirrorRetentionPolicy: mirrorRetentionPolicy
            )

            activeIngressControllers[id] = ingress

            print(
                """
                [HordePortalMirror] retention policy selected
                  wave: \(wave)
                  retainMirrorsThroughWave: \(HordePortalMirrorOptimizationSettings.retainMirrorsThroughWave)
                  enemyID: \(id)
                  policy: \(mirrorRetentionPolicy.rawValue)
                """
            )

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

    private func enqueueDeathReplacementIfNeeded(
        deadEnemyID: UUID,
        deadController: JockRetargetTestController,
        wave: Int
    ) {
        guard hordeBenchmarkRunning,
              !isPlayerDeathSequenceActive,
              var state = hordeDeathReplacementState,
              state.runID == currentHordeRunID,
              state.wave == wave,
              state.hasReplacementRemaining else {
            return
        }

        guard !state.deathIDsThatConsumedToken.contains(deadEnemyID) else {
            print(
                """
                [HordeReplacement] duplicate death ignored
                  wave: \(wave)
                  deadEnemyID: \(deadEnemyID)
                  reason: token_already_consumed_for_death
                """
            )
            return
        }

        let occupiedOrReserved =
            authoritativeLivingOrIngressEnemyCount() +
            state.pendingReplacementCount

        guard occupiedOrReserved < HordeWaveRules.maxConcurrentCombatants else {
            assertionFailure("Death replacement had no available combatant vacancy")

            print(
                """
                [HordeReplacement] ERROR replacement not queued
                  wave: \(wave)
                  deadEnemyID: \(deadEnemyID)
                  reason: no_combatant_vacancy_after_death
                  livingOrIngress: \(authoritativeLivingOrIngressEnemyCount())
                  reserved: \(state.pendingReplacementCount)
                """
            )
            return
        }

        let replacementEnemyID = UUID()
        let replacementSpawnIndex = nextGlobalEnemySpawnIndex
        nextGlobalEnemySpawnIndex += 1

        let request = HordeDeathReplacementRequest(
            runID: state.runID,
            waveGeneration: state.generation,
            deadEnemyID: deadEnemyID,
            replacementEnemyID: replacementEnemyID,
            wave: wave,
            archetype: deadController.archetype,
            replacementSpawnIndex: replacementSpawnIndex
        )

        state.consumedReplacementCount += 1
        state.deathIDsThatConsumedToken.insert(deadEnemyID)
        state.reservedReplacementEnemyIDs.insert(replacementEnemyID)
        state.corpseIDsEligibleForReplacementCleanup.insert(deadEnemyID)
        state.queuedRequests.append(request)

        hordeDeathReplacementState = state

        print(
            """
            [HordeReplacement] replacement queued
              runID: \(state.runID)
              generation: \(state.generation)
              wave: \(wave)
              deadEnemyID: \(deadEnemyID)
              archetype: \(deadController.archetype.rawValue)
              replacementEnemyID: \(replacementEnemyID)
              consumed: \(state.consumedReplacementCount)/\(state.replacementBudget)
              queueDepth: \(state.queuedRequests.count)
              reservedCount: \(state.pendingReplacementCount)
              cleanupDeadCorpseAfterDelay: true
            """
        )

        assertHordeReplacementInvariants(
            context: "enqueueDeathReplacementIfNeeded"
        )

        ensureHordeReplacementPumpRunning()
    }

    private func spawnDeathReplacementThroughPortal(
        _ request: HordeDeathReplacementRequest
    ) async {
        var stagedController: JockRetargetTestController?
        var registrationSucceeded = false

        do {
            guard isCurrentReplacementRequest(request) else {
                cancelOrFailStaleReplacementRequest(
                    request,
                    stage: "initial_validation"
                )
                return
            }

            let spawnPose = spatialProvider.currentPoseOrFallback()
            let attributes = try CharacterAttributeStore.shared.attributes(
                for: request.archetype
            )
            let hitsToKill = attributes.horde.hitsToKill.random()

            guard await ensureWavePrewarmed(
                wave: request.wave,
                lineup: [request.archetype]
            ) else {
                throw NSError(
                    domain: "HordeReplacement",
                    code: 501,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Replacement prewarm failed"
                    ]
                )
            }

            guard isCurrentReplacementRequest(request) else {
                cancelOrFailStaleReplacementRequest(
                    request,
                    stage: "after_prewarm"
                )
                return
            }

            let assignment = try await portalAssignmentForDeathReplacement(
                request,
                spawnPose: spawnPose
            )

            guard isCurrentReplacementRequest(request) else {
                cancelOrFailStaleReplacementRequest(
                    request,
                    stage: "after_portal_assignment"
                )
                return
            }

            guard let portal = hordePortalManager.portals[assignment.portalID] else {
                throw NSError(
                    domain: "HordeReplacement",
                    code: 502,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Assigned replacement portal missing \(assignment.portalID)."
                    ]
                )
            }

            let spawnPosition = portal.root.position(relativeTo: nil)

            let controller = try await createLoadedHordeEnemyController(
                id: request.replacementEnemyID,
                archetype: request.archetype,
                position: spawnPosition,
                wave: request.wave,
                spawnIndex: request.replacementSpawnIndex,
                hitsToKill: hitsToKill,
                playerHeadPosition: spawnPose.headPosition
            )

            stagedController = controller

            guard isCurrentReplacementRequest(request) else {
                cleanupStagedReplacementController(
                    controller,
                    enemyID: request.replacementEnemyID,
                    reason: "replacement_request_stale_after_controller_create"
                )
                stagedController = nil
                cancelOrFailStaleReplacementRequest(
                    request,
                    stage: "after_controller_create"
                )
                return
            }

            try registerHordeEnemyForInstancedPortalIngress(
                controller: controller,
                id: request.replacementEnemyID,
                archetype: request.archetype,
                wave: request.wave,
                spawnIndex: request.replacementSpawnIndex,
                portal: portal,
                side: assignment.side,
                assignmentKind: assignment.assignmentKind,
                currentHeadPosition: spatialProvider.currentPose()?.headPosition ?? spawnPose.headPosition
            )

            registrationSucceeded = true
            stagedController = nil

            completeDeathReplacementRequest(
                request,
                portalID: portal.id,
                side: assignment.side
            )
        } catch {
            if !registrationSucceeded,
               let stagedController {
                cleanupStagedReplacementController(
                    stagedController,
                    enemyID: request.replacementEnemyID,
                    reason: "replacement_spawn_failed"
                )
            }

            failDeathReplacementRequestIfCurrent(
                request,
                stage: "spawn_transaction",
                error: error
            )
        }
    }

    private func portalAssignmentForDeathReplacement(
        _ request: HordeDeathReplacementRequest,
        spawnPose: PhaseOneSpawnPose
    ) async throws -> HordePortalAssignment {
        let maxAttempts = 8
        let retryDelayNanoseconds: UInt64 = 100_000_000

        for attempt in 1...maxAttempts {
            guard isCurrentReplacementRequest(request) else {
                throw NSError(
                    domain: "HordeReplacement",
                    code: 503,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Replacement request became stale before portal assignment."
                    ]
                )
            }

            let assignments = await HordePortalWaveAssignmentPlanner(
                portalManager: hordePortalManager
            )
            .buildAssignmentsForWave(
                wave: request.wave,
                spawnRequests: [
                    (
                        id: request.replacementEnemyID,
                        archetype: request.archetype
                    )
                ],
                playerPosition: spawnPose.headPosition,
                playerForward: spawnPose.headForward
            )

            if let assignment = assignments.first {
                return assignment
            }

            guard attempt < maxAttempts else {
                break
            }

            print(
                """
                [HordeReplacement] portal assignment waiting
                  runID: \(request.runID)
                  generation: \(request.waveGeneration)
                  wave: \(request.wave)
                  replacementEnemyID: \(request.replacementEnemyID)
                  archetype: \(request.archetype.rawValue)
                  attempt: \(attempt)
                  maxAttempts: \(maxAttempts)
                """
            )

            try await Task.sleep(
                nanoseconds: retryDelayNanoseconds
            )
        }

        throw NSError(
            domain: "HordeReplacement",
            code: 504,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "No portal available for replacement after bounded retry."
            ]
        )
    }

    private func completeDeathReplacementRequest(
        _ request: HordeDeathReplacementRequest,
        portalID: UUID,
        side: HordePortalEntranceSide
    ) {
        guard var state = hordeDeathReplacementState,
              state.runID == request.runID,
              state.generation == request.waveGeneration,
              state.wave == request.wave else {
            print(
                """
                [HordeReplacement] request cancelled as stale
                  stage: complete_after_registration
                  wave: \(request.wave)
                  replacementEnemyID: \(request.replacementEnemyID)
                """
            )
            return
        }

        state.successfulReplacementCount += 1
        state.inFlightRequest = nil
        state.reservedReplacementEnemyIDs.remove(
            request.replacementEnemyID
        )
        hordeDeathReplacementState = state

        hordePortalManager.markEntranceUsed(
            portalID: portalID
        )
        hordeTotalSpawned += 1

        print(
            """
            [HordeReplacement] replacement registered through portal
              runID: \(request.runID)
              generation: \(request.waveGeneration)
              wave: \(request.wave)
              deadEnemyID: \(request.deadEnemyID)
              replacementEnemyID: \(request.replacementEnemyID)
              archetype: \(request.archetype.rawValue)
              spawnIndex: \(request.replacementSpawnIndex)
              portalID: \(portalID)
              side: \(side.rawValue)
              successful: \(state.successfulReplacementCount)
              reservedCount: \(state.pendingReplacementCount)
              usesNormalPortalIngress: true
            """
        )

        assertHordeReplacementInvariants(
            context: "completeDeathReplacementRequest"
        )
    }

    private func failDeathReplacementRequestIfCurrent(
        _ request: HordeDeathReplacementRequest,
        stage: String,
        error: Error
    ) {
        guard var state = hordeDeathReplacementState,
              state.runID == request.runID,
              state.generation == request.waveGeneration,
              state.wave == request.wave,
              state.reservedReplacementEnemyIDs.contains(request.replacementEnemyID) else {
            print(
                """
                [HordeReplacement] request cancelled as stale
                  stage: \(stage)
                  wave: \(request.wave)
                  replacementEnemyID: \(request.replacementEnemyID)
                  error: \(error.localizedDescription)
                """
            )
            return
        }

        state.failedReplacementCount += 1
        state.inFlightRequest = nil
        state.reservedReplacementEnemyIDs.remove(
            request.replacementEnemyID
        )
        hordeDeathReplacementState = state

        hordeSpawnFailures.append(
            HordeSpawnFailureRecord(
                wave: request.wave,
                spawnIndex: request.replacementSpawnIndex,
                archetype: request.archetype,
                reason: "Replacement spawn failed at \(stage): \(error.localizedDescription)"
            )
        )

        if hordeWaveSpawnState == .active {
            hordeWaveSpawnState = .degraded
        }

        print(
            """
            [HordeReplacement] replacement failed
              runID: \(request.runID)
              generation: \(request.waveGeneration)
              wave: \(request.wave)
              deadEnemyID: \(request.deadEnemyID)
              replacementEnemyID: \(request.replacementEnemyID)
              archetype: \(request.archetype.rawValue)
              spawnIndex: \(request.replacementSpawnIndex)
              stage: \(stage)
              error: \(error.localizedDescription)
              failed: \(state.failedReplacementCount)
              reservedCount: \(state.pendingReplacementCount)
              retry: false
            """
        )

        assertHordeReplacementInvariants(
            context: "failDeathReplacementRequestIfCurrent"
        )
    }

    private func cancelOrFailStaleReplacementRequest(
        _ request: HordeDeathReplacementRequest,
        stage: String
    ) {
        let error = NSError(
            domain: "HordeReplacement",
            code: 505,
            userInfo: [
                NSLocalizedDescriptionKey: "Replacement request is stale at \(stage)."
            ]
        )

        failDeathReplacementRequestIfCurrent(
            request,
            stage: stage,
            error: error
        )
    }

    private func cleanupStagedReplacementController(
        _ controller: JockRetargetTestController,
        enemyID: UUID,
        reason: String
    ) {
        audioController.stopHostAudioSource(
            id: enemyID
        )
        cleanupPortalMirror(
            enemyID: enemyID,
            reason: reason
        )
        activeHordeEnemyIDs.remove(enemyID)
        hordeEnemyControllersByID.removeValue(
            forKey: enemyID
        )
        controller.forceCleanupFromHordeScene(
            reason: reason
        )
        recycleHordePrewarmedAssets(
            from: controller
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
        resetHordeDeathReplacementRuntime(
            reason: "clear_horde_enemy_controllers"
        )

        for (id, controller) in hordeEnemyControllersByID {
            audioController.stopHostAudioSource(id: id)
            cleanupPortalMirror(
                enemyID: id,
                reason: "clear_live_horde_enemy_controllers"
            )
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

        storyTitleCardTransitionCoordinator.cancelForDeath()
        Task { @MainActor [weak self] in
            await self?.chapter03Coordinator?.cancel(
                reason: "actualPlayerDeath.horde"
            )
        }

        isPlayerDeathSequenceActive = true
        hordeRuntimePhase = .playerDead
        submitHordeScoresIfNeeded(
            reason: "player_death"
        )
        pendingNextBenchmarkWaveTask?.cancel()
        pendingNextBenchmarkWaveTask = nil
        resetHordeDeathReplacementRuntime(
            reason: "player_death"
        )
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
        let youDiedOriginFromDevice = spatialProvider.currentTrackedDeviceTransform()

        if let youDiedOriginFromDevice {
            print(
                """
                [YouDied] sampled device pose
                  reason: player_death_accepted
                  fallbackUsed: false
                  originFromDeviceColumnW: \(youDiedOriginFromDevice.columns.3)
                """
            )
        } else {
            print(
                """
                [YouDied] failed: no tracked device pose at player death
                  reason: player_death_accepted
                  fallbackUsed: false
                """
            )
        }

        onPlayerDeathStarted?()
        clearInstructionHUDForPlayerDeath()

        deathPresentationController?.playDeathBlackoutSequence { [weak self] in
            guard let self else { return }

            self.clearHordeEnemiesAfterDeathBlackout()

            if let youDiedOriginFromDevice {
                if let onYouDiedWorldCardRequested = self.onYouDiedWorldCardRequested {
                    onYouDiedWorldCardRequested(
                        youDiedOriginFromDevice
                    )
                } else {
                    print(
                        """
                        [YouDied] failed: presenter callback unavailable
                          reason: final_dark
                          fallbackUsed: false
                        """
                    )
                }
            } else {
                print(
                    """
                    [YouDied] skipped world card
                      reason: missing_sampled_device_pose
                      fallbackUsed: false
                    """
                )
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

            print("[PlagueDeath] lights coming back up.")
        }
    }

    private func handleChapter01PlayerDeath(
        source: ChapterPlayerDeathSource
    ) {
        guard !isPlayerDeathSequenceActive else { return }

        storyTitleCardTransitionCoordinator.cancelForDeath()
        Task { @MainActor [weak self] in
            await self?.chapter03Coordinator?.cancel(
                reason: "actualPlayerDeath.chapter01"
            )
        }

        isPlayerDeathSequenceActive = true

        let deathAudioDuration =
            audioController.playRandomPlayerDeathAndReturnDuration()
        let youDiedOriginFromDevice =
            spatialProvider.currentTrackedDeviceTransform()

        print(
            """
            [Chapter01PlayerDeath] handling player death
              source: \(source.rawValue)
              confirmedHits: \(source.confirmedHitsToKill)
              deathAudioDuration: \(String(format: "%.3f", deathAudioDuration))
              hasTrackedDevicePose: \(youDiedOriginFromDevice != nil)
            """
        )

        clearInstructionHUDForPlayerDeath()

        deathPresentationController?.playDeathBlackoutSequence { [weak self] in
            guard let self else { return }

            if let youDiedOriginFromDevice,
               let onYouDiedWorldCardRequested {
                onYouDiedWorldCardRequested(youDiedOriginFromDevice)
            } else {
                print(
                    """
                    [YouDied] Chapter01 world card unavailable
                      source: \(source.rawValue)
                      hasTrackedDevicePose: \(youDiedOriginFromDevice != nil)
                      hasPresenter: \(self.onYouDiedWorldCardRequested != nil)
                    """
                )
            }

            print(
                "[Chapter01PlayerDeath] final dark reached; " +
                    "source=\(source.rawValue) you_died presentation requested"
            )
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            let presentationDelay = Task { @MainActor in
                let delay = deathAudioDuration + 3.0
                try? await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            }
            if source == .dadFinalBattle {
                await self.chapter01DadFinalBattleCoordinator?
                    .waitUntilRuntimeReleased()
            }
            await presentationDelay.value

            guard self.isPlayerDeathSequenceActive else { return }

            let finishPresentation: @MainActor () -> Void = { [weak self] in
                guard let self,
                      self.isPlayerDeathSequenceActive else { return }

                self.isPlayerDeathSequenceActive = false
                self.onYouDiedWorldCardCleanupRequested?()
                self.onPlayerDeathStarted?()

                print(
                    "[Chapter01PlayerDeath] black faded out; " +
                        "source=\(source.rawValue) Story episode picker requested"
                )
            }

            if let deathPresentationController = self.deathPresentationController {
                deathPresentationController.fadeBackUp(
                    duration: 1.25,
                    onCompleted: finishPresentation
                )
            } else {
                finishPresentation()
            }

            print(
                "[Chapter01PlayerDeath] lights coming back up " +
                    "source=\(source.rawValue)"
            )
        }
    }

    private func resetHordeBenchmarkDeathPresentation() {
        pendingNextBenchmarkWaveTask?.cancel()
        pendingNextBenchmarkWaveTask = nil
        isPlayerDeathSequenceActive = false
        jockRetargetController?.setPlayerAttackEnabled(true)
        deathPresentationController?.reset()
        onYouDiedWorldCardCleanupRequested?()
    }

    private func clearHordeEnemiesAfterDeathBlackout() {
        for (id, controller) in hordeEnemyControllersByID {
            audioController.stopHostAudioSource(id: id)
            cleanupPortalMirror(
                enemyID: id,
                reason: "player_death"
            )
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
        retainPortalMirrorForEnemyIfNeeded(
            enemyID: id
        )
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

        enqueueDeathReplacementIfNeeded(
            deadEnemyID: id,
            deadController: controller,
            wave: wave
        )

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

            scheduleReplacementCorpseCleanupIfNeeded(
                enemyID: id,
                wave: wave
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

    private func scheduleReplacementCorpseCleanupIfNeeded(
        enemyID: UUID,
        wave: Int
    ) {
        guard var state = hordeDeathReplacementState,
              state.runID == currentHordeRunID,
              state.wave == wave,
              state.corpseIDsEligibleForReplacementCleanup.remove(enemyID) != nil else {
            return
        }

        let runID = state.runID
        let generation = state.generation

        hordeDeathReplacementState = state

        hordeReplacementCorpseCleanupTasksByEnemyID[enemyID]?.cancel()

        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        HordeWaveRules.replacementCorpseCleanupDelaySeconds *
                            1_000_000_000
                    )
                )
            } catch {
                return
            }

            guard let self,
                  let currentState = self.hordeDeathReplacementState,
                  currentState.runID == runID,
                  currentState.generation == generation,
                  currentState.wave == wave else {
                return
            }

            self.cleanupSingleHordeCorpse(
                enemyID: enemyID,
                reason: "replacement_spawn_memory_cap"
            )
        }

        hordeReplacementCorpseCleanupTasksByEnemyID[enemyID] = task

        print(
            """
            [HordeReplacement] corpse cleanup scheduled
              wave: \(wave)
              enemyID: \(enemyID)
              delaySeconds: \(HordeWaveRules.replacementCorpseCleanupDelaySeconds)
              cleanupOnlyThisCorpse: true
            """
        )
    }

    @MainActor
    private func cleanupSingleHordeCorpse(
        enemyID: UUID,
        reason: String
    ) {
        hordeReplacementCorpseCleanupTasksByEnemyID[enemyID]?.cancel()
        hordeReplacementCorpseCleanupTasksByEnemyID.removeValue(
            forKey: enemyID
        )

        guard let record = hordeCorpseRecordsByID.removeValue(
            forKey: enemyID
        ) else {
            corpseHordeEnemyIDs.remove(enemyID)
            return
        }

        corpseHordeEnemyIDs.remove(enemyID)
        audioController.stopHostAudioSource(
            id: enemyID
        )
        cleanupPortalMirror(
            enemyID: enemyID,
            reason: reason
        )
        record.controller.forceCleanupFromHordeScene(
            reason: reason
        )
        recycleHordePrewarmedAssets(
            from: record.controller
        )

        print(
            """
            [HordeReplacement] corpse cleaned
              enemyID: \(enemyID)
              characterID: \(record.characterID)
              reason: \(reason)
              otherCorpsesUnaffected: true
            """
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

        let pendingReplacementCount: Int

        if let state = hordeDeathReplacementState,
           state.runID == currentHordeRunID,
           state.wave == wave {
            pendingReplacementCount = state.pendingReplacementCount
        } else {
            pendingReplacementCount = 0
        }

        let livingOrIngressCount = authoritativeLivingOrIngressEnemyCount()

        guard livingOrIngressCount == 0,
              dyingHordeEnemyIDs.isEmpty,
              pendingReplacementCount == 0 else {
            print(
                """
                [HordeBenchmark] wave not clear yet
                  wave: \(wave)
                  livingOrIngress: \(livingOrIngressCount)
                  dying: \(dyingHordeEnemyIDs.count)
                  pendingReplacements: \(pendingReplacementCount)
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
            cleanupPortalMirror(
                enemyID: enemyID,
                reason: reason
            )
            controller.forceCleanupFromHordeScene(
                reason: reason
            )
            recycleHordePrewarmedAssets(
                from: controller
            )
        }

        hordeDyingEnemyControllersByID.removeAll()
        dyingHordeEnemyIDs.removeAll()

        for enemyID in Array(hordeCorpseRecordsByID.keys) {
            cleanupSingleHordeCorpse(
                enemyID: enemyID,
                reason: reason
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

    private func validateDeathPresentationAssets() {
        if Bundle.main.url(
            forResource: "you_died",
            withExtension: "png"
        ) == nil {
            print("[PlagueDeath] WARNING you_died.png not found in main bundle")
        }
    }
}

extension PlagueImmersiveCoordinator: StoryTitleCardTransitionWorld {
    func currentTitleCardDeviceTransform() -> simd_float4x4? {
        spatialProvider.currentTrackedDeviceTransform()
    }

    func acquireTitleCardTransitionLease(
        transitionID: UUID,
        source: String
    ) async throws -> StoryInteractionLease {
        try await turingDoorBundleController
            .closeUnloadAndTransferToStoryTransition(
                transitionID: transitionID,
                reason: "titleCard.\(source)"
            )
    }

    func commitTitleCardDestination(
        _ destination: StoryTitleCardDestination,
        transitionLease: StoryInteractionLease,
        requestID: UUID
    ) async throws -> StoryTitleCardRouteLeaseDisposition {
        try await StoryInteractionArbiter.shared.requireCurrent(
            transitionLease
        )

        try await prepareConversationMicrophones(
            for: destination,
            requestID: requestID
        )

        let disposition: StoryTitleCardRouteLeaseDisposition
        switch destination {
        case .start(.prologue):
            try await StoryInteractionArbiter.shared.setStableInteractionPolicy(
                .unrestricted,
                storyTransitionLease: transitionLease,
                reason: "titleCard.start.prologue"
            )
            await Chapter01ProgressStore.shared.clear(
                reason: "titleCard.start.prologue"
            )
            TuringStoryProgressStore.shared.clear(
                reason: "titleCard.start.prologue"
            )
            await TuringProloguePostBattleProgressStore.shared.clear(
                reason: "titleCard.start.prologue"
            )
            let plan = try TuringStoryDestinationPlanner
                .startOfEpisode(.prologue)
            try await TuringStoryStateTeleportCoordinator.shared.apply(
                plan,
                source: "titleCard.start.prologue",
                storyTransitionLease: transitionLease
            )
            disposition = .releaseAfterFade

        case .start(.chapter01):
            TuringStoryProgressStore.shared.clear(
                reason: "titleCard.start.chapter01"
            )
            guard let chapter01Coordinator else {
                throw StoryTitleCardError.missingRouteOwner
            }
            try await chapter01Coordinator.beginAtRoot(
                transitionLease: transitionLease
            )
            disposition = .releaseAfterFade

        case .start(.chapter02):
            guard let chapter02Coordinator else {
                throw StoryTitleCardError.missingRouteOwner
            }
            try await chapter02Coordinator.beginAtRoot(
                transitionLease: transitionLease
            )
            disposition = .retainedByDestination

        case .start(.chapter03):
            guard let chapter03Coordinator else {
                throw StoryTitleCardError.missingRouteOwner
            }
            try await chapter03Coordinator.beginAtRoot(
                chapterRunID: requestID,
                transitionLease: transitionLease,
                blackoutRequestID: requestID,
                resetProgress: true
            )
            disposition = .transferredByDestination

        case .continueFrom(.prologue(let snapshot)):
            try await StoryInteractionArbiter.shared.setStableInteractionPolicy(
                .unrestricted,
                storyTransitionLease: transitionLease,
                reason: "titleCard.continue.prologue"
            )
            let plan = try TuringStoryDestinationPlanner.destination(
                for: snapshot,
                experienceMode: .play
            )
            try await TuringStoryStateTeleportCoordinator.shared.apply(
                plan,
                source: "titleCard.continue.prologue",
                storyTransitionLease: transitionLease
            )
            disposition = plan.battleState == .battle01Start
                ? .retainedByDestination
                : .releaseAfterFade

        case .continueFrom(.chapter01(let snapshot)):
            guard let chapter01Coordinator else {
                throw StoryTitleCardError.missingRouteOwner
            }
            disposition = try await chapter01Coordinator
                .resumeFromSavedCheckpoint(
                    frozenSnapshot: snapshot,
                    transitionLease: transitionLease
                )

        case .continueFrom(.chapter02(let snapshot)):
            guard let chapter02Coordinator else {
                throw StoryTitleCardError.missingRouteOwner
            }
            disposition = try await chapter02Coordinator
                .resumeFromSavedCheckpoint(
                    snapshot: snapshot,
                    transitionLease: transitionLease
                )

        case .continueFrom(.chapter03(let snapshot)):
            guard let chapter03Coordinator else {
                throw StoryTitleCardError.missingRouteOwner
            }
            disposition = try await chapter03Coordinator
                .resumeFromSavedCheckpoint(
                    snapshot: snapshot,
                    transitionLease: transitionLease,
                    requestID: requestID
                )

        case .advance(let completed, let next):
            guard TuringEpisodeCatalog.nextUnlockedEpisode(after: completed) == next else {
                throw StoryTitleCardError.invalidNaturalDestination
            }
            switch (completed, next) {
            case (.prologue, .chapter01):
                guard let chapter01Coordinator else {
                    throw StoryTitleCardError.missingRouteOwner
                }
                try await chapter01Coordinator.beginAtRoot(
                    transitionLease: transitionLease
                )
                try await prologueCompletionCoordinator?
                    .commitPendingEpisodeBoundary()
                disposition = .releaseAfterFade

            case (.chapter01, .chapter02):
                guard let chapter02Coordinator else {
                    throw StoryTitleCardError.missingRouteOwner
                }
                try await chapter02Coordinator.beginAtRoot(
                    transitionLease: transitionLease
                )
                disposition = .retainedByDestination

            case (.chapter02, .chapter03):
                guard let chapter03Coordinator else {
                    throw StoryTitleCardError.missingRouteOwner
                }
                try await chapter03Coordinator.beginAtRoot(
                    chapterRunID: requestID,
                    transitionLease: transitionLease,
                    blackoutRequestID: requestID,
                    resetProgress: true
                )
                disposition = .transferredByDestination

            default:
                throw StoryTitleCardError.invalidNaturalDestination
            }

        case .endOfAvailableContent(let completedEpisode):
            guard TuringEpisodeCatalog.nextUnlockedEpisode(
                after: completedEpisode
            ) == nil else {
                throw StoryTitleCardError
                    .terminalCardUsedWithUnlockedSuccessor
            }
            if completedEpisode == .chapter03 {
                guard let chapter03Coordinator else {
                    throw StoryTitleCardError.missingRouteOwner
                }
                try await chapter03Coordinator.markEndCardRouteCommitted(
                    sourceEventID: requestID
                )
            }
            disposition = .releaseAfterFade
        }

        print(
            """
            [StoryTitleCard] route committed
              requestID: \(requestID.uuidString)
              destination: \(destination)
              noRescan: true
              leaseDisposition: \(disposition)
            """
        )
        return disposition
    }

    private func prepareConversationMicrophones(
        for destination: StoryTitleCardDestination,
        requestID: UUID
    ) async throws {
        let arbiter = StoryInteractionArbiter.shared
        switch destination {
        case .start(let episodeID), .advance(_, let episodeID):
            let store = try TuringLiveConversationCatalogStore()
            guard let segment = store.firstSegment(for: episodeID) else {
                throw TuringRuntimeError.invalidConfig(
                    "No initial microphone segment exists for \(episodeID.rawValue)."
                )
            }
            _ = await arbiter.beginConversationChapter(
                episodeID: episodeID,
                segmentID: segment.segmentID,
                reason: "titleCard.\(requestID.uuidString)"
            )

        case .continueFrom(let target):
            let generation = await arbiter
                .currentConversationMicrophoneGeneration()
            let rehydration = try TuringConversationMicrophoneRehydrator()
                .resolveSlots(
                    target: target,
                    generation: generation
                )
            _ = await arbiter.replaceConversationMicrophonesForContinue(
                episodeID: rehydration.episodeID,
                segmentID: rehydration.segmentID,
                slots: rehydration.slots,
                reason: "titleCard.\(requestID.uuidString)"
            )

        case .endOfAvailableContent(let episodeID):
            _ = await arbiter.clearConversationMicrophones(
                boundary: .chapter(episodeID),
                reason: "titleCard.end.\(requestID.uuidString)"
            )
        }
    }

    func titleCardTransitionDidFullyFade(
        _ destination: StoryTitleCardDestination,
        requestID: UUID
    ) async throws {
        switch destination {
        case .start(.chapter02),
             .continueFrom(.chapter02),
             .advance(from: .chapter01, to: .chapter02):
            guard let chapter02Coordinator else {
                throw StoryTitleCardError.missingRouteOwner
            }
            try await chapter02Coordinator.titleCardDidFullyFade(
                requestID: requestID
            )

        case .start(.chapter03),
             .continueFrom(.chapter03),
             .advance(from: .chapter02, to: .chapter03):
            guard let chapter03Coordinator else {
                throw StoryTitleCardError.missingRouteOwner
            }
            try await chapter03Coordinator.titleCardDidFullyFade(
                requestID: requestID
            )

        case .start,
             .continueFrom,
             .advance,
             .endOfAvailableContent:
            break
        }
    }

    func titleCardTransitionCompleted(
        _ destination: StoryTitleCardDestination,
        requestID: UUID
    ) async {
        if destination.returnsToOperationMenuAfterCompletion {
            onOperationMenuRequested?(
                "endOfAvailableContent.\(destination.episodeID.rawValue)"
            )
            return
        }

        guard case .continueFrom(.chapter02) = destination,
              let chapter02Coordinator else {
            return
        }
        do {
            guard let lease = try await chapter02Coordinator
                .takeTerminalContinuationLease(requestID: requestID) else {
                return
            }
            let request = StoryTitleCardTransitionRequest(
                requestID: requestID,
                source: .naturalEpisodeBoundary,
                descriptor: StoryTitleCardCatalog.endOfAvailableContent,
                destination: .endOfAvailableContent(
                    completedEpisode: .chapter02
                ),
                menuMusicPolicy: .unchanged
            )
            try storyTitleCardTransitionCoordinator.accept(
                request,
                ownership: .transferred(lease)
            )
        } catch {
            await StoryInteractionArbiter.shared
                .releaseCurrentStoryTransition(
                    transitionID: requestID,
                    reason: "chapter02TerminalContinuationFailed"
                )
            showTemporaryInstructionHUD(
                "Story transition failed: \(error.localizedDescription)",
                clearAfterSeconds: 4,
                reason: "chapter02TerminalContinuationFailed"
            )
        }
    }

    func titleCardTransitionFailed(
        _ error: Error,
        request: StoryTitleCardTransitionRequest
    ) {
        showTemporaryInstructionHUD(
            "Story transition failed: \(error.localizedDescription)",
            clearAfterSeconds: 4,
            reason: "titleCardFailed.\(request.requestID.uuidString)"
        )
        onStoryEpisodePickerRequested?(
            "titleCardFailed.\(request.source.rawValue)"
        )
        print(
            "[StoryTitleCard] route failure requestID=" +
                request.requestID.uuidString +
                " error=\(error.localizedDescription)"
        )
        if case .advance(from: .prologue, to: .chapter01) = request.destination {
            Task { @MainActor [weak self] in
                await self?.prologueCompletionCoordinator?
                    .episodeBoundaryFailed(reason: error.localizedDescription)
            }
        }
        switch request.destination {
        case .start(.chapter02),
             .continueFrom(.chapter02),
             .advance(from: .chapter01, to: .chapter02):
            Task { @MainActor [weak self] in
                await self?.chapter02Coordinator?.cancel(
                    reason: "titleCardFailed.\(request.requestID.uuidString)"
                )
            }
        case .start(.chapter03),
             .continueFrom(.chapter03),
             .endOfAvailableContent(completedEpisode: .chapter03):
            Task { @MainActor [weak self] in
                await self?.chapter03Coordinator?.cancel(
                    reason: "titleCardFailed.\(request.requestID.uuidString)"
                )
            }
        default:
            break
        }
    }

    private func handleStoryEpisodeBoundary(
        _ event: StoryEpisodeBoundaryEvent
    ) async throws {
        guard event.actualTerminalPlaybackCompleted else {
            throw StoryTitleCardError.terminalPlaybackIncomplete
        }

        let transitionID = UUID()
        let lease = try await TuringEpisodeFlowController.shared
            .transferActiveInteractionToStoryTransition(
                transitionID: transitionID,
                reason: "episodeBoundary.\(event.completedEpisodeID.rawValue)"
            )
        try await acceptStoryEpisodeBoundary(
            event,
            transitionID: transitionID,
            lease: lease
        )
    }

    private func acceptStoryEpisodeBoundary(
        _ event: StoryEpisodeBoundaryEvent,
        transitionID: UUID,
        lease: StoryInteractionLease
    ) async throws {
        let request: StoryTitleCardTransitionRequest
        if let next = TuringEpisodeCatalog.nextUnlockedEpisode(
            after: event.completedEpisodeID
        ) {
            request = StoryTitleCardTransitionRequest(
                requestID: transitionID,
                source: .naturalEpisodeBoundary,
                descriptor: StoryTitleCardCatalog.descriptor(for: next),
                destination: .advance(
                    from: event.completedEpisodeID,
                    to: next
                ),
                menuMusicPolicy: .unchanged
            )
        } else {
            request = StoryTitleCardTransitionRequest(
                requestID: transitionID,
                source: .naturalEpisodeBoundary,
                descriptor: StoryTitleCardCatalog.endOfAvailableContent,
                destination: .endOfAvailableContent(
                    completedEpisode: event.completedEpisodeID
                ),
                menuMusicPolicy: .unchanged
            )
        }

        do {
            try storyTitleCardTransitionCoordinator.accept(
                request,
                ownership: .transferred(lease)
            )
        } catch {
            await StoryInteractionArbiter.shared.release(
                lease,
                reason: "episodeBoundaryTitleRejected"
            )
            throw error
        }
    }

}
