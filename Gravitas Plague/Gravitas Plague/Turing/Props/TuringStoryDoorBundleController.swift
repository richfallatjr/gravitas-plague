import Combine
import Foundation
import RealityKit
import simd
import UIKit

@MainActor
final class TuringStoryDoorBundleController:
    ObservableObject,
    TuringStoryAdjustablePlacementController {
    enum BundleError: LocalizedError {
        case missingUSDZ(String)
        case missingRequiredEntity(String)
        case noWallManager
        case noPlacement

        var errorDescription: String? {
            switch self {
            case .missingUSDZ(let name):
                return "Missing Story door bundle USDZ: \(name)"
            case .missingRequiredEntity(let name):
                return "Missing required Story door bundle entity: \(name)"
            case .noWallManager:
                return "Missing wall manager for Story door bundle placement."
            case .noPlacement:
                return "No valid wall placement for Story door bundle."
            }
        }
    }

    private struct DoorConfig: Codable {
        var schemaVersion: Int
        var bundleID: String
        var usdz: String
        var defaultOpenYawDegrees: Float
        var openDurationSeconds: Double
        var closeDurationSeconds: Double
        var preferredCenterHeightMeters: Float
        var defaultWidthMeters: Float
        var defaultHeightMeters: Float
        var defaultDepthOffsetMeters: Float
        var occupancyPaddingMeters: Float
        var portalWorldProvider: String
        var occlusionEnabled: Bool
        var sfx: SFXConfig

        struct SFXConfig: Codable {
            var open: String
            var closeSqueak: String
            var closeContact: String
        }

        static let fallback = DoorConfig(
            schemaVersion: 1,
            bundleID: "turing_story_door_bundle_v1",
            usdz: "turing_story_door_bundle_v1.usdz",
            defaultOpenYawDegrees: -145.0,
            openDurationSeconds: 1.15,
            closeDurationSeconds: 0.95,
            preferredCenterHeightMeters: TuringStoryDoorBundleTuning
                .preferredCenterHeightMeters,
            defaultWidthMeters: TuringStoryDoorBundleTuning.defaultWidthMeters,
            defaultHeightMeters: TuringStoryDoorBundleTuning.defaultHeightMeters,
            defaultDepthOffsetMeters: TuringStoryDoorBundleTuning.depthOffset,
            occupancyPaddingMeters: TuringStoryDoorBundleTuning
                .occupancyPaddingMeters,
            portalWorldProvider: TuringStoryDoorPortalContentProvider.providerID,
            occlusionEnabled: true,
            sfx: SFXConfig(
                open: "door-open-creak-01.wav",
                closeSqueak: "door-close-squeak-01.wav",
                closeContact: "door-close-contact-01.wav"
            )
        )
    }

    final class PortalOnlyEntity {
        let name: String
        let authoredPortalTransform: simd_float4x4
        var source: Entity?

        init(
            name: String,
            source: Entity,
            authoredPortalTransform: simd_float4x4
        ) {
            self.name = name
            self.source = source
            self.authoredPortalTransform = authoredPortalTransform
        }
    }

    struct Anchors {
        let bundleRoot: Entity
        let frameRoot: Entity
        let hingePivot: Entity
        let doorPanelRoot: Entity
        let portalPlane: Entity
        let iconAnchor: Entity
        let audioEmitter: Entity
        let placementBounds: Entity?
        let glass: Entity?
        let portalOnlyEntities: [PortalOnlyEntity]
        let zombieA1: Entity
        let zombieA2: Entity
        let zombieA3: Entity
    }

    private static let portalOnlyEntityNames = [
        "TuringStoryDoorPortalSlab_Root",
        "TuringStoryDoorPortalFence_Root",
        "TuringStoryDoorPortalFirewood_Root"
    ]

    let root = Entity()
    private let portalWorldRoot = Entity()
    private var loadedBundleRoot: Entity?
    private(set) var anchors: Anchors?

    private weak var wallManager: WallPlaneManager?
    private weak var occupancyRegistry: WallPropOccupancyRegistry?

    private let occupancyID = UUID()
    private var committedAdjustmentTransform: simd_float4x4?
    private var committedAdjustmentSlot: TuringStoryRuntimeSlot?
    private var config = DoorConfig.fallback
    private(set) var placement: TuringStoryDoorBundlePlacement?
    private(set) var isPlaced = false
    private var activeAtmosphere: PortalHDRIAtmosphere = .night
    private var animationController: TuringStoryDoorAnimationController?
    private let portalLifecycle =
        TuringStoryDoorPortalLifecycleController()
    private let portalResourceLoader =
        TuringStoryDoorPortalResourceLoader()
    private var storyInteractionLease: StoryInteractionLease?
    private var latestInteractionSnapshot = StoryInteractionSnapshot(
        revision: 0,
        turingGate: .closed,
        doorState: .closedUnloaded,
        exclusiveOwner: nil,
        capabilities: [],
        walkiePresentation: .hidden,
        doorPresentation: .hidden
    )
    private var battleInteractionLockOwnerIDs = Set<UUID>()
    private var battlePortalOwnerIDs = Set<UUID>()
    private var portalRequiredByDoorState = false
    private var portalWorldLoaded = false
    private var portalLoadTask: Task<Void, Error>?
    private var portalOpenRequestTask: Task<Void, Never>?
    private var portalTransitionTask: Task<Void, Never>?
    private let iconController = TuringStoryDoorIconController()
    private var loadedVisualMinY: Float = 0
    private var loadedVisualMaxY: Float = TuringStoryDoorBundleTuning
        .defaultHeightMeters

    init() {
        root.name = "TuringStoryDoorBundle_WorldRoot"
        root.isEnabled = false

        portalWorldRoot.name = "TuringStoryDoorPortalWorldRoot"
        portalWorldRoot.components.set(WorldComponent())
        root.addChild(portalWorldRoot)
    }

    func installIfNeeded(
        sceneRoot: Entity,
        wallManager: WallPlaneManager,
        occupancyRegistry: WallPropOccupancyRegistry
    ) {
        self.wallManager = wallManager
        self.occupancyRegistry = occupancyRegistry

        if root.parent == nil {
            sceneRoot.addChild(root)
        }

        print("[TuringDoorBundle] installed")
    }

    func prepareForPlannedPlacement() async throws {
        config = loadConfig()
        let loadedRoot = try await loadBundleIfNeeded()
        anchors = try resolveAnchors(in: loadedRoot)
    }

    func commitPlannedPlacement(
        _ plannedPlacement: TuringStoryDoorBundlePlacement,
        semanticReservation: WallLocalRect,
        atmosphere: PortalHDRIAtmosphere
    ) async throws {
        guard let wallManager else { throw BundleError.noWallManager }
        if anchors == nil { try await prepareForPlannedPlacement() }
        guard let resolvedAnchors = anchors,
              let transform = worldTransform(
                placement: plannedPlacement,
                wallManager: wallManager
              ) else { throw BundleError.noPlacement }
        root.setTransformMatrix(transform, relativeTo: nil)
        root.isEnabled = true
        placement = plannedPlacement
        isPlaced = true
        committedAdjustmentTransform = transform
        committedAdjustmentSlot = nil
        activeAtmosphere = atmosphere
        registerOccupancy(
            placement: plannedPlacement,
            semanticReservation: semanticReservation
        )
        logFloorSnapProof(placement: plannedPlacement, wallManager: wallManager)
        await bindRuntimeMaterialsAndPortal(
            anchors: resolvedAnchors,
            atmosphere: atmosphere,
            placement: plannedPlacement
        )
        installAnimationController(anchors: resolvedAnchors)
        iconController.install(
            anchor: resolvedAnchors.iconAnchor,
            doorPanel: resolvedAnchors.doorPanelRoot
        )
        applyInteractionSnapshot(
            await StoryInteractionArbiter.shared.currentSnapshot()
        )
        portalLifecycle.recoverClosedUnloaded()
        updateInteractionPresentation()
    }

    func placeOnBestWallIfNeeded(
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>,
        atmosphere: PortalHDRIAtmosphere
    ) async -> Bool {
        if isPlaced {
            await updateAtmosphereIfNeeded(atmosphere)
            return true
        }

        guard let wallManager else {
            print("[TuringDoorBundle] ERROR missing wallManager")
            return false
        }

        do {
            config = loadConfig()
            let loadedRoot = try await loadBundleIfNeeded()
            let resolvedAnchors = try resolveAnchors(in: loadedRoot)
            anchors = resolvedAnchors

            guard let selectedPlacement = choosePlacement(
                wallManager: wallManager,
                playerPosition: playerPosition,
                playerForward: playerForward
            ) else {
                throw BundleError.noPlacement
            }

            guard let transform = worldTransform(
                placement: selectedPlacement,
                wallManager: wallManager
            ) else {
                throw BundleError.noPlacement
            }

            root.setTransformMatrix(
                transform,
                relativeTo: nil
            )
            root.isEnabled = true
            placement = selectedPlacement
            isPlaced = true
            committedAdjustmentTransform = transform
            committedAdjustmentSlot = nil
            activeAtmosphere = atmosphere

            registerOccupancy(placement: selectedPlacement)
            logFloorSnapProof(
                placement: selectedPlacement,
                wallManager: wallManager
            )
            await bindRuntimeMaterialsAndPortal(
                anchors: resolvedAnchors,
                atmosphere: atmosphere,
                placement: selectedPlacement
            )
            installAnimationController(anchors: resolvedAnchors)
            iconController.install(
                anchor: resolvedAnchors.iconAnchor,
                doorPanel: resolvedAnchors.doorPanelRoot
            )
            applyInteractionSnapshot(
                await StoryInteractionArbiter.shared.currentSnapshot()
            )
            portalLifecycle.recoverClosedUnloaded()
            updateInteractionPresentation()

            print(
                """
                [TuringDoorBundle] placement committed
                  wallID: \(selectedPlacement.wallID)
                  localX: \(selectedPlacement.localX)
                  localY: \(selectedPlacement.localY)
                  width: \(selectedPlacement.width)
                  height: \(selectedPlacement.height)
                  floorWorldY: \(selectedPlacement.floorWorldY.map { "\($0)" } ?? "nil")
                  visualHeight: \(loadedVisualHeight)
                  heightPlacementSource: scanned_floor_snap_no_visual_height_reject
                  preferredCenterHeightMeters: \(config.preferredCenterHeightMeters)
                  overlapsPoster: false
                  overlapsPortal: false
                  atmosphere: \(atmosphere.rawValue)
                """
            )

            return true
        } catch {
            print(
                """
                [TuringDoorBundle] ERROR placement failed
                  error: \(error.localizedDescription)
                """
            )
            return false
        }
    }

    func updateAtmosphereIfNeeded(
        _ atmosphere: PortalHDRIAtmosphere
    ) async {
        guard let placement else {
            return
        }

        activeAtmosphere = atmosphere
        if portalWorldLoaded {
            await reloadPortalWorld(
                atmosphere: atmosphere,
                placement: placement
            )
        }

        print(
            """
            [TuringDoorPortal] atmosphere changed
              atmosphere: \(atmosphere.rawValue)
              portalWorldLoaded: \(portalWorldLoaded)
              reloadDeferredUntilNextDemand: \(!portalWorldLoaded)
            """
        )
    }

    func toggleDoor(
        reason: String
    ) {
        print(
            """
            [TuringDoorTrigger] tapped
              doorID: storyDoor.primary
              reason: \(reason)
            """
        )
        switch latestInteractionSnapshot.doorPresentation {
        case .open:
            requestDoorOpen(reason: reason)
        case .close:
            requestPlayerDoorClose(reason: reason)
        case .hidden:
            print(
                "[TuringDoorTrigger] transition tap ignored reason=\(reason) state=\(portalLifecycle.state)"
            )
        }
    }

    func setDoorStateImmediatelyForStoryTeleport(
        _ destination: TuringStoryDoorDestination,
        teleportID: UUID
    ) {
        battleInteractionLockOwnerIDs.removeAll(keepingCapacity: false)
        portalLifecycle.setBattleInteractionLocked(false)
        switch destination {
        case .closed:
            let staleDoorInteractionLease = storyInteractionLease
            storyInteractionLease = nil
            portalOpenRequestTask?.cancel()
            portalTransitionTask?.cancel()
            animationController?.setStateImmediatelyForStoryTeleport(
                .closed,
                teleportID: teleportID
            )
            portalRequiredByDoorState = false
            reconcilePortalDemand(reason: "storyTeleport.closed")
            portalLifecycle.recoverClosedUnloaded()
            updateInteractionPresentation()
            if let staleDoorInteractionLease {
                Task {
                    await StoryInteractionArbiter.shared.release(
                        staleDoorInteractionLease,
                        reason: "storyTeleportClosed"
                    )
                }
            }
        case .open:
            requestDoorOpen(
                reason: "storyTeleport.\(teleportID.uuidString)"
            )
        }
    }

    var battleDoorState: TuringStoryDoorBattleState {
        switch animationController?.state ?? .closed {
        case .closed:
            return .closed
        case .opening:
            return .opening
        case .open:
            return .open
        case .closing:
            return .closing
        }
    }

    var doorPortalLifecycleState: TuringStoryDoorPortalState {
        portalLifecycle.state
    }

    var isFullExteriorLoaded: Bool {
        portalWorldLoaded &&
            portalWorldRoot.children.isEmpty == false &&
            firstPortalIBLEntity(in: portalWorldRoot) != nil
    }

    var battlePortalFullExteriorResident: Bool {
        portalWorldLoaded ||
            portalWorldRoot.children.isEmpty == false ||
            (anchors?.portalOnlyEntities.contains { $0.source != nil } ?? false)
    }

    func ensureClosedAndUnloadedForTuring(reason: String) async throws {
        portalLifecycle.setTuringPreflightActive(true)
        updateInteractionPresentation()
        defer {
            portalLifecycle.setTuringPreflightActive(false)
            updateInteractionPresentation()
        }

        guard portalLifecycle.isBattleOwned == false,
              battlePortalOwnerIDs.isEmpty else {
            throw TuringRuntimeError.invalidConfig(
                "Door portal is still owned by an active battle."
            )
        }

        print("""
        [TuringHighMemoryPreflight] door close/unload requested
          reason: \(reason)
          lifecycleState: \(portalLifecycle.state)
          doorState: \(battleDoorState.rawValue)
          fullExteriorLoaded: \(battlePortalFullExteriorResident)
        """)

        if let lease = portalLifecycle.activeLease {
            guard lease.owner == .player else {
                throw TuringRuntimeError.invalidConfig(
                    "Turing preflight cannot revoke a battle portal lease."
                )
            }
            try await closeDoorAndUnload(
                lease: lease,
                reason: "turingPreflight.\(reason)"
            )
        } else {
            guard battleDoorState == .closed else {
                throw TuringRuntimeError.invalidConfig(
                    "Open Story door has no portal lease."
                )
            }
            portalLoadTask?.cancel()
            if let portalLoadTask {
                _ = try? await portalLoadTask.value
            }
            self.portalLoadTask = nil
            portalRequiredByDoorState = false
            unloadPortalWorld(reason: "turingPreflight.\(reason)")
            portalLifecycle.recoverClosedUnloaded()
        }

        guard battleDoorState == .closed,
              battlePortalFullExteriorResident == false,
              portalLifecycle.state == .closedUnloaded else {
            throw TuringRuntimeError.invalidConfig(
                "Door portal remained resident after Turing memory preflight."
            )
        }

        print("""
        [TuringHighMemoryPreflight] door close/unload completed
          reason: \(reason)
          lifecycleState: closedUnloaded
          fullExteriorLoaded: false
        """)
    }

    func closeUnloadAndTransferToTuring(
        runID: String,
        reason: String
    ) async throws -> StoryInteractionLease {
        guard let doorLease = storyInteractionLease,
              let portalLease = portalLifecycle.activeLease,
              portalLease.owner == .player else {
            return try await StoryInteractionArbiter.shared
                .claimAutomaticTuring(
                    runID: runID,
                    source: reason
                )
        }

        try await closeDoorAndUnload(
            lease: portalLease,
            reason: "automaticTuring.\(reason)"
        )
        await StoryInteractionArbiter.shared.updateDoorState(
            .closedUnloaded,
            reason: "automaticTuring.\(reason)"
        )
        let turingLease = try await StoryInteractionArbiter.shared
            .transferDoorToTuring(
                doorLease: doorLease,
                runID: runID,
                reason: reason
            )
        storyInteractionLease = nil
        return turingLease
    }

    func setBattleInteractionLocked(
        _ locked: Bool,
        ownerID: UUID,
        reason: String
    ) {
        if locked {
            battleInteractionLockOwnerIDs.insert(ownerID)
        } else {
            battleInteractionLockOwnerIDs.remove(ownerID)
        }
        portalLifecycle.setBattleInteractionLocked(
            battleInteractionLockOwnerIDs.isEmpty == false
        )
        updateInteractionPresentation()

        print("""
        [TuringDoorBattle] interaction lock changed
          locked: \(locked)
          ownerID: \(ownerID.uuidString)
          activeOwnerCount: \(battleInteractionLockOwnerIDs.count)
          reason: \(reason)
        """)
    }

    func acquireBattlePortal(
        ownerID: UUID,
        reason: String
    ) async throws {
        let interactionSnapshot = await StoryInteractionArbiter.shared
            .currentSnapshot()
        guard interactionSnapshot.exclusiveOwner == .battle(
            battleInstanceID: ownerID
        ) else {
            throw StoryInteractionClaimError.staleLease
        }
        let isNewBattleOwnership = battlePortalOwnerIDs.contains(ownerID) == false
        if isNewBattleOwnership {
            setBattleInteractionLocked(
                false,
                ownerID: ownerID,
                reason: "battleAcquire.\(reason)"
            )
        }
        portalOpenRequestTask?.cancel()
        portalOpenRequestTask = nil
        battlePortalOwnerIDs = [ownerID]
        let lease = portalLifecycle.acquireForBattle(
            battleInstanceID: ownerID,
            fullExteriorLoaded: portalWorldLoaded,
            doorState: battleDoorState
        )
        portalRequiredByDoorState = battleDoorState != .closed
        updateInteractionPresentation()
        do {
            try await ensurePortalWorldLoaded(reason: "battleAcquire.\(reason)")
            if battleDoorState == .closed {
                portalLifecycle.markClosedReady(lease: lease)
            }
            assertDoorPortalInvariant(context: "battleAcquire.\(reason)")
            print("""
            [TuringDoorPortal] battle lease acquired
              ownerID: \(ownerID.uuidString)
              leaseID: \(lease.id.uuidString)
              activeBattleOwnerCount: \(battlePortalOwnerIDs.count)
              portalWorldLoaded: \(portalWorldLoaded)
              reason: \(reason)
            """)
        } catch {
            battlePortalOwnerIDs.remove(ownerID)
            portalLifecycle.fail(error, lease: lease)
            reconcilePortalDemand(reason: "battleAcquireFailed.\(reason)")
            updateInteractionPresentation()
            throw error
        }
    }

    func releaseBattlePortal(
        ownerID: UUID,
        reason: String
    ) {
        guard battleDoorState == .closed else {
            print("""
            [TuringDoorPortal] battle lease release refused
              ownerID: \(ownerID.uuidString)
              doorState: \(battleDoorState.rawValue)
              portalRetained: true
              reason: \(reason)
            """)
            return
        }
        battlePortalOwnerIDs.remove(ownerID)
        portalRequiredByDoorState = false
        reconcilePortalDemand(reason: "battleRelease.\(reason)")
        if battlePortalOwnerIDs.isEmpty,
           battlePortalFullExteriorResident == false {
            portalLifecycle.finishUnloaded(
                lease: portalLifecycle.activeLease
            )
        }
        updateInteractionPresentation()
        print("""
        [TuringDoorPortal] battle lease released
          ownerID: \(ownerID.uuidString)
          activeBattleOwnerCount: \(battlePortalOwnerIDs.count)
          doorState: \(battleDoorState.rawValue)
          reason: \(reason)
        """)
    }

    func openForBattle(
        ownerID: UUID,
        reason: String
    ) async throws {
        guard let animationController else {
            throw BundleError.noPlacement
        }

        setBattleInteractionLocked(
            true,
            ownerID: ownerID,
            reason: reason
        )
        guard let lease = portalLifecycle.activeLease,
              lease.owner == .battle(ownerID) else {
            throw BundleError.noPlacement
        }
        try await ensurePortalWorldLoaded(reason: "Battle01.\(reason).doorOpen")
        portalLifecycle.markClosedReady(lease: lease)
        portalLifecycle.markOpening(lease: lease)
        updateInteractionPresentation()
        try await animationController.openAndWait(
            reason: "Battle01.\(reason)"
        )
        guard animationController.state == .open else {
            throw BundleError.noPlacement
        }
        portalLifecycle.markOpen(lease: lease)
        updateInteractionPresentation()
        assertDoorPortalInvariant(context: "battleOpen.\(reason)")
    }

    func closeForBattleAndUnloadPortal(
        ownerID: UUID,
        reason: String
    ) async throws {
        guard let animationController else {
            throw BundleError.noPlacement
        }

        setBattleInteractionLocked(true, ownerID: ownerID, reason: reason)
        guard let lease = portalLifecycle.activeLease,
              lease.owner == .battle(ownerID) else {
            throw BundleError.noPlacement
        }
        portalRequiredByDoorState = true
        portalLifecycle.markClosing(lease: lease)
        updateInteractionPresentation()
        try await animationController.closeAndWait(
            reason: "Battle01.\(reason)"
        )
        guard animationController.state == .closed else {
            throw BundleError.noPlacement
        }
        portalLifecycle.markClosedReady(lease: lease)
        let unloadRequestID = UUID()
        portalLifecycle.markUnloading(
            requestID: unloadRequestID,
            lease: lease
        )
        battlePortalOwnerIDs.remove(ownerID)
        portalRequiredByDoorState = false
        updateInteractionPresentation()
        unloadPortalWorld(
            reason: "battleClose.\(reason)",
            requestID: unloadRequestID
        )
        portalLifecycle.finishUnloaded(lease: lease)
        updateInteractionPresentation()
        guard animationController.state == .closed,
              battlePortalFullExteriorResident == false else {
            throw BundleError.noPlacement
        }
        await StoryInteractionArbiter.shared.updateDoorState(
            .closedUnloaded,
            reason: "battleClose.\(reason)"
        )
        print("""
        [TuringDoorPortal] battle close and unload completed
          ownerID: \(ownerID.uuidString)
          doorState: \(battleDoorState.rawValue)
          closeAnimationCompleted: true
          closeSFXActualCompletion: true
          fullExteriorResident: \(battlePortalFullExteriorResident)
          reason: \(reason)
        """)
    }

    func battlePortalContext() throws -> TuringStoryDoorBattlePortalContext {
        guard isPlaced,
              let anchors,
              isFullExteriorLoaded else {
            throw BundleError.noPlacement
        }

        for anchor in [anchors.zombieA1, anchors.zombieA2, anchors.zombieA3] {
            print("""
            [TuringDoorBattle] anchor resolved
              name: \(anchor.name)
              doorLocal: \(anchor.transformMatrix(relativeTo: root))
              portalWorldLocal: \(anchor.transformMatrix(relativeTo: portalWorldRoot))
              world: \(anchor.transformMatrix(relativeTo: nil))
            """)
        }

        return TuringStoryDoorBattlePortalContext(
            doorRoot: root,
            portalWorldRoot: portalWorldRoot,
            portalPlane: anchors.portalPlane,
            zombieA1: anchors.zombieA1,
            zombieA2: anchors.zombieA2,
            zombieA3: anchors.zombieA3,
            doorAudioEmitter: anchors.audioEmitter
        )
    }

    func reset(
        reason: String
    ) {
        let staleInteractionLease = storyInteractionLease
        storyInteractionLease = nil
        animationController?.cancel(reason: reason)
        animationController = nil
        battleInteractionLockOwnerIDs.removeAll(keepingCapacity: false)
        battlePortalOwnerIDs.removeAll(keepingCapacity: false)
        portalRequiredByDoorState = false
        portalOpenRequestTask?.cancel()
        portalOpenRequestTask = nil
        portalTransitionTask?.cancel()
        portalTransitionTask = nil
        portalLoadTask?.cancel()
        portalLoadTask = nil
        portalWorldLoaded = false
        iconController.remove()
        occupancyRegistry?.unregister(id: occupancyID)
        root.children.removeAll()
        root.addChild(portalWorldRoot)
        root.isEnabled = false
        loadedBundleRoot = nil
        anchors = nil
        placement = nil
        isPlaced = false
        committedAdjustmentTransform = nil
        committedAdjustmentSlot = nil
        portalWorldRoot.children.removeAll()
        portalWorldRoot.components.set(WorldComponent())
        portalLifecycle.reset()
        portalResourceLoader.clearPreparedAndCachedExterior(
            portalWorld: portalWorldRoot,
            reason: "reset.\(reason)"
        )
        Task {
            if let staleInteractionLease {
                await StoryInteractionArbiter.shared.release(
                    staleInteractionLease,
                    reason: "doorReset.\(reason)"
                )
            }
            await StoryInteractionArbiter.shared.updateDoorState(
                .closedUnloaded,
                reason: "doorReset.\(reason)"
            )
        }

        print(
            """
            [TuringDoorBundle] reset
              reason: \(reason)
            """
        )
    }

    private func loadConfig() -> DoorConfig {
        let url = Bundle.main.url(
            forResource: "turing_story_door_bundle_v1",
            withExtension: "json",
            subdirectory: "Turing/Props"
        ) ?? Bundle.main.url(
            forResource: "turing_story_door_bundle_v1",
            withExtension: "json"
        )

        guard let url else {
            print(
                """
                [TuringDoorBundle] config missing; using defaults
                  file: turing_story_door_bundle_v1.json
                """
            )
            return .fallback
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(
                DoorConfig.self,
                from: data
            )
            return decoded
        } catch {
            print(
                """
                [TuringDoorBundle] ERROR config decode failed; using defaults
                  file: turing_story_door_bundle_v1.json
                  error: \(error.localizedDescription)
                """
            )
            return .fallback
        }
    }

    private func loadBundleIfNeeded() async throws -> Entity {
        if let loadedBundleRoot {
            return loadedBundleRoot
        }

        guard let url = doorBundleURL() else {
            throw BundleError.missingUSDZ("turing_story_door_bundle_v1.usdz")
        }

        let entity = try await Entity(contentsOf: url)
        if entity.name.isEmpty || entity.name == "root" {
            entity.name = "TuringStoryDoorBundle_Root"
        }
        entity.scale = SIMD3<Float>(
            repeating: TuringStoryDoorBundleTuning.assetImportScale
        )

        root.children.removeAll()
        root.addChild(entity)
        root.addChild(portalWorldRoot)
        updateLoadedVisualBounds()
        prunePortalOnlyEntitiesFromPassthrough(in: entity)
        applyOcclusionPlaneMaterialIfPresent(
            in: entity,
            bundleURL: url
        )
        loadedBundleRoot = entity

        print(
            """
            [TuringDoorBundle] USDZ loaded
              file: turing_story_door_bundle_v1.usdz
              rootName: \(entity.name)
              assetImportScale: \(TuringStoryDoorBundleTuning.assetImportScale)
              visualMinY: \(loadedVisualMinY)
              visualMaxY: \(loadedVisualMaxY)
            """
        )

        return entity
    }

    private func updateLoadedVisualBounds() {
        let bounds = root.visualBounds(
            recursive: true,
            relativeTo: root,
            excludeInactive: false
        )
        let minY = bounds.min.y
        let maxY = bounds.max.y

        guard minY.isFinite,
              maxY.isFinite,
              maxY > minY else {
            loadedVisualMinY = 0
            loadedVisualMaxY = config.defaultHeightMeters
            print(
                """
                [TuringDoorBundle] visual bounds unavailable; using config height
                  fallbackMinY: \(loadedVisualMinY)
                  fallbackMaxY: \(loadedVisualMaxY)
                """
            )
            return
        }

        loadedVisualMinY = minY
        loadedVisualMaxY = maxY

        print(
            """
            [TuringDoorBundle] visual bounds measured
              minY: \(loadedVisualMinY)
              maxY: \(loadedVisualMaxY)
              height: \(loadedVisualHeight)
            """
        )
    }

    private var loadedVisualCenterY: Float {
        (loadedVisualMinY + loadedVisualMaxY) * 0.5
    }

    private var loadedVisualHeight: Float {
        max(0.001, loadedVisualMaxY - loadedVisualMinY)
    }

    private func applyOcclusionPlaneMaterialIfPresent(
        in root: Entity,
        bundleURL: URL
    ) {
        guard let occlusionEntity =
                root.turingDoorFindEntity(containingNormalized: "occlusion01") ??
                root.turingDoorFindEntity(containingNormalized: "occlusion")
        else {
            print(
                """
                [TuringDoorPortal] occlusion mesh not found
                  expectedEntityName: occlusion-01
                  fallbackEntityName: occlusion
                  action: occlusion_mask_disabled
                """
            )
            return
        }

        guard let maskURL = extractEmbeddedOcclusionMaskURL(
            bundleURL: bundleURL
        ) else {
            occlusionEntity.isEnabled = false
            print(
                """
                [TuringDoorPortal] occlusion mask texture not found
                  entity: \(occlusionEntity.name)
                  expectedEmbedded: textures/ao.png
                  fallbackEmbedded: ao.png
                  rule: white_opaque_black_transparent
                  action: hide_occlusion_mesh_until_embedded_mask_exists
                """
            )
            return
        }

        do {
            let texture = try PortalGlyphMaskTextureCache.shared
                .textureForMaskPNG(url: maskURL)
            var material = UnlitMaterial()
            material.color = .init(
                tint: UIColor.black,
                texture: .init(texture)
            )
            material.blending = .transparent(
                opacity: .init(floatLiteral: 1.0)
            )
            material.faceCulling = .none

            let modelCount = overrideMaterialsRecursively(
                under: occlusionEntity,
                with: material
            )
            guard modelCount > 0 else {
                print(
                    """
                    [TuringDoorPortal] occlusion mesh has no ModelComponent
                      entity: \(occlusionEntity.name)
                      action: occlusion_mask_disabled
                    """
                )
                return
            }

            print(
                """
                [TuringDoorPortal] occlusion mask material applied
                  entity: \(occlusionEntity.name)
                  texture: \(maskURL.lastPathComponent)
                  rule: glyph_mask_white_opaque_black_transparent
                  blackIsMask: false
                  visibleColor: black
                  material: unlit_alpha_mask
                  faceCulling: none
                  usdzAuthoredMaterialOverridden: true
                  modelComponentsUpdated: \(modelCount)
                  inputDisabled: true
                """
            )
        } catch {
            print(
                """
                [TuringDoorPortal] ERROR occlusion mask material failed
                  entity: \(occlusionEntity.name)
                  texture: \(maskURL.lastPathComponent)
                  error: \(error.localizedDescription)
                  action: preserve_authored_material
                """
            )
        }
    }

    @discardableResult
    private func overrideMaterialsRecursively(
        under entity: Entity,
        with material: RealityKit.Material
    ) -> Int {
        var updatedCount = 0

        if var model = entity.components[ModelComponent.self] {
            model.materials = [material]
            entity.components.set(model)
            updatedCount += 1
        }

        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(CollisionComponent.self)

        for child in entity.children {
            updatedCount += overrideMaterialsRecursively(
                under: child,
                with: material
            )
        }

        return updatedCount
    }

    private func extractEmbeddedOcclusionMaskURL(
        bundleURL: URL
    ) -> URL? {
        guard let archive = try? Data(
            contentsOf: bundleURL,
            options: .mappedIfSafe
        ) else {
            return nil
        }

        let targets: Set<String> = [
            "textures/ao.png",
            "ao.png"
        ]
        var offset = 0

        while offset + 30 <= archive.count {
            guard archive.turingDoorZIPUInt32(at: offset) == 0x04034b50 else {
                offset += 1
                continue
            }

            let compressionMethod = archive.turingDoorZIPUInt16(
                at: offset + 8
            )
            let compressedSize = Int(
                archive.turingDoorZIPUInt32(
                    at: offset + 18
                )
            )
            let uncompressedSize = Int(
                archive.turingDoorZIPUInt32(
                    at: offset + 22
                )
            )
            let fileNameLength = Int(
                archive.turingDoorZIPUInt16(
                    at: offset + 26
                )
            )
            let extraFieldLength = Int(
                archive.turingDoorZIPUInt16(
                    at: offset + 28
                )
            )
            let fileNameStart = offset + 30
            let fileNameEnd = fileNameStart + fileNameLength
            let dataStart = fileNameEnd + extraFieldLength
            let dataLength = compressedSize > 0
                ? compressedSize
                : uncompressedSize
            let dataEnd = dataStart + dataLength

            guard fileNameEnd <= archive.count,
                  dataStart <= archive.count else {
                return nil
            }

            let nameData = archive[fileNameStart..<fileNameEnd]
            let fileName = String(
                data: nameData,
                encoding: .utf8
            )?.lowercased()

            if let fileName,
               targets.contains(fileName),
               compressionMethod == 0,
               dataLength > 0,
               dataEnd <= archive.count {
                let outputURL = embeddedOcclusionMaskCacheURL(
                    bundleURL: bundleURL
                )

                do {
                    try archive
                        .subdata(in: dataStart..<dataEnd)
                        .write(
                            to: outputURL,
                            options: .atomic
                        )

                    print(
                        """
                        [TuringDoorPortal] embedded occlusion mask extracted
                          usdz: \(bundleURL.lastPathComponent)
                          embeddedPath: \(fileName)
                          output: \(outputURL.lastPathComponent)
                          source: embedded_usdz_texture
                        """
                    )

                    return outputURL
                } catch {
                    print(
                        """
                        [TuringDoorPortal] ERROR embedded occlusion mask extract failed
                          usdz: \(bundleURL.lastPathComponent)
                          embeddedPath: \(fileName)
                          error: \(error.localizedDescription)
                        """
                    )
                    return nil
                }
            }

            offset = max(
                offset + 1,
                dataEnd
            )
        }

        return nil
    }

    private func embeddedOcclusionMaskCacheURL(
        bundleURL: URL
    ) -> URL {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: bundleURL.path
        )
        let fileSize = attributes?[.size] as? NSNumber
        let modified = attributes?[.modificationDate] as? Date
        let stamp = "\(fileSize?.intValue ?? 0)_\(Int(modified?.timeIntervalSince1970 ?? 0))"
        let name = "\(bundleURL.deletingPathExtension().lastPathComponent)_embedded_ao_\(stamp).png"

        return FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
    }

    private func resolveAnchors(
        in root: Entity
    ) throws -> Anchors {
        guard let frameRoot = root.turingDoorFindEntity(
            named: "TuringStoryDoorFrame_Root"
        ) else {
            throw BundleError.missingRequiredEntity("TuringStoryDoorFrame_Root")
        }
        guard let hingePivot = root.turingDoorFindEntity(
            named: "TuringStoryDoorHingePivot"
        ) else {
            throw BundleError.missingRequiredEntity("TuringStoryDoorHingePivot")
        }
        guard let doorPanelRoot = root.turingDoorFindEntity(
            named: "TuringStoryDoorPanel_Root"
        ) else {
            throw BundleError.missingRequiredEntity("TuringStoryDoorPanel_Root")
        }
        guard let portalPlane = root.turingDoorFindEntity(
            named: "TuringStoryDoorPortalPlane"
        ) else {
            throw BundleError.missingRequiredEntity("TuringStoryDoorPortalPlane")
        }
        guard let zombieA1 = root.turingDoorFindEntity(named: "zombie_a1") else {
            throw BundleError.missingRequiredEntity("zombie_a1")
        }
        guard let zombieA2 = root.turingDoorFindEntity(named: "zombie_a2") else {
            throw BundleError.missingRequiredEntity("zombie_a2")
        }
        guard let zombieA3 = root.turingDoorFindEntity(named: "zombie_a3") else {
            throw BundleError.missingRequiredEntity("zombie_a3")
        }
        let portalOnlyEntities = Self.portalOnlyEntityNames.compactMap { name -> PortalOnlyEntity? in
            guard let source = root.turingDoorFindEntity(named: name) else { return nil }
            return PortalOnlyEntity(
                name: name,
                source: source,
                authoredPortalTransform: source.transformMatrix(relativeTo: portalWorldRoot)
            )
        }
        let iconAnchor = proceduralAnchorIfMissing(
            named: "TuringStoryDoorIconAnchor",
            under: root,
            fallbackLocalPosition: SIMD3<Float>(0, 1.18, 0.08)
        )
        let audioEmitter = proceduralAnchorIfMissing(
            named: "TuringStoryDoorAudioEmitter",
            under: root,
            fallbackLocalPosition: SIMD3<Float>(-0.42, 0.95, 0.06)
        )

        ensureDoorPanelIsChildOfHinge(
            doorPanelRoot: doorPanelRoot,
            hingePivot: hingePivot
        )

        let anchors = Anchors(
            bundleRoot: root,
            frameRoot: frameRoot,
            hingePivot: hingePivot,
            doorPanelRoot: doorPanelRoot,
            portalPlane: portalPlane,
            iconAnchor: iconAnchor,
            audioEmitter: audioEmitter,
            placementBounds: root.turingDoorFindEntity(
                named: "TuringStoryDoorPlacementBounds"
            ),
            glass: root.turingDoorFindEntity(
                named: "TuringStoryDoorGlass"
            ),
            portalOnlyEntities: portalOnlyEntities,
            zombieA1: zombieA1,
            zombieA2: zombieA2,
            zombieA3: zombieA3
        )

        print(
            """
            [TuringDoorBundle] required anchors resolved
              frameRoot: \(anchors.frameRoot.name)
              hingePivot: \(anchors.hingePivot.name)
              doorPanelRoot: \(anchors.doorPanelRoot.name)
              portalPlane: \(anchors.portalPlane.name)
              iconAnchor: \(anchors.iconAnchor.name)
              audioEmitter: \(anchors.audioEmitter.name)
              placementBounds: \(anchors.placementBounds?.name ?? "nil")
              portalOnlyEntities: \(anchors.portalOnlyEntities.map(\.name).joined(separator: ","))
              portalSource: authored
            """
        )

        return anchors
    }

    private func proceduralAnchorIfMissing(
        named name: String,
        under parent: Entity,
        fallbackLocalPosition: SIMD3<Float>
    ) -> Entity {
        if let existing = parent.turingDoorFindEntity(named: name) {
            return existing
        }

        let entity = Entity()
        entity.name = name
        entity.position = fallbackLocalPosition
        parent.addChild(entity)

        print(
            """
            [TuringDoorBundle] procedural anchor added
              name: \(name)
              parent: \(parent.name)
              localPosition: \(fallbackLocalPosition)
              reason: non_visual_anchor_missing_from_usdz
            """
        )

        return entity
    }

    private func ensureDoorPanelIsChildOfHinge(
        doorPanelRoot: Entity,
        hingePivot: Entity
    ) {
        if let parent = doorPanelRoot.parent,
           parent === hingePivot {
            return
        }

        doorPanelRoot.setParent(
            hingePivot,
            preservingWorldTransform: true
        )

        print(
            """
            [TuringDoorBundle] door panel reparented to hinge pivot
              hingePivot: TuringStoryDoorHingePivot
              doorPanelRoot: TuringStoryDoorPanel_Root
              preservingWorldTransform: true
              reason: authored_panel_was_not_child_of_hinge
            """
        )
    }

    private func bindRuntimeMaterialsAndPortal(
        anchors: Anchors,
        atmosphere: PortalHDRIAtmosphere,
        placement: TuringStoryDoorBundlePlacement
    ) async {
        if let glass = anchors.glass {
            TuringStoryWindowGlassMaterialFactory.applyGlassMaterialRecursively(
                to: glass
            )
        }

        anchors.audioEmitter.components.set(SpatialAudioComponent())
        let portalModelCount = bindPortalComponentRecursively(
            to: anchors.portalPlane
        )

        unloadPortalWorld(reason: "initialClosedPlacement")

        print(
            """
            [TuringDoorPortal] portal bound
              portalPlane: TuringStoryDoorPortalPlane
              material: PortalMaterial
              target: TuringStoryDoorPortalWorldRoot
              occlusionEnabled: true
              portalModelComponentsUpdated: \(portalModelCount)
              exteriorLifecycle: demand_loaded
              initialState: unloaded_closed
            """
        )
    }

    @discardableResult
    private func bindPortalComponentRecursively(
        to entity: Entity
    ) -> Int {
        var boundCount = 0

        if var model = entity.components[ModelComponent.self] {
            model.materials = [PortalMaterial()]
            entity.components.set(model)
            entity.components.set(
                PortalComponent(
                    target: portalWorldRoot
                )
            )
            boundCount += 1
        }

        for child in entity.children {
            boundCount += bindPortalComponentRecursively(
                to: child
            )
        }

        if boundCount == 0 {
            entity.components.set(
                PortalComponent(
                    target: portalWorldRoot
                )
            )
        }

        return boundCount
    }

    private func reloadPortalWorld(
        atmosphere: PortalHDRIAtmosphere,
        placement: TuringStoryDoorBundlePlacement
    ) async {
        let replacementWorld = Entity()
        replacementWorld.name = "TuringStoryDoorPortalWorld_Replacement"
        replacementWorld.components.set(WorldComponent())
        defer {
            portalResourceLoader.clearPreparedAndCachedExterior(
                portalWorld: replacementWorld,
                reason: "atmosphereReplacementReleased"
            )
        }

        do {
            try await portalResourceLoader.populateFullExterior(
                portalWorld: replacementWorld,
                atmosphere: atmosphere,
                placement: placement
            )
            guard portalDemandActive else {
                unloadPortalWorld(reason: "atmosphereReloadDemandEnded")
                return
            }
            if let anchors {
                for record in anchors.portalOnlyEntities {
                    record.source?.removeFromParent()
                }
                portalWorldRoot.children.removeAll()
                for child in Array(replacementWorld.children) {
                    child.removeFromParent()
                    portalWorldRoot.addChild(child)
                }
                installPortalOnlyEntities(anchors: anchors)
                setEnabledRecursively(anchors.portalPlane, isEnabled: true)
            }
            portalWorldLoaded = true
            print("""
            [TuringDoorPortal] exterior loaded
              atmosphere: \(atmosphere.rawValue)
              reason: atmosphereReload
              activeBattleOwnerCount: \(battlePortalOwnerIDs.count)
              doorState: \(battleDoorState.rawValue)
            """)
        } catch {
            print(
                """
                [TuringDoorPortal] ERROR portal world reload failed
                  atmosphere: \(atmosphere.rawValue)
                  error: \(error.localizedDescription)
                """
            )
        }
    }

    private func requestDoorOpen(reason: String) {
        if case .battle(let battleInstanceID) =
            latestInteractionSnapshot.exclusiveOwner {
            requestBattleDoorOpen(
                ownerID: battleInstanceID,
                reason: reason
            )
            return
        }

        guard portalOpenRequestTask == nil,
              portalTransitionTask == nil else {
            print("[TuringDoorPortal] duplicate open request ignored reason=\(reason)")
            return
        }
        portalOpenRequestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.portalOpenRequestTask = nil }
            var claimedStoryLease: StoryInteractionLease?
            do {
                let storyLease = try await StoryInteractionArbiter.shared
                    .claimManualDoor(source: reason)
                claimedStoryLease = storyLease
                guard let claim = self.portalLifecycle.beginPlayerOpen() else {
                    throw StoryInteractionClaimError.invalidTransfer
                }
                let lease = claim.lease
                let requestID = claim.requestID
                self.storyInteractionLease = storyLease
                self.portalRequiredByDoorState = true
                self.updateInteractionPresentation()
                print("""
                [TuringDoorPortal] manual open requested
                  storyLeaseID: \(storyLease.id.uuidString)
                  portalLeaseID: \(lease.id.uuidString)
                  requestID: \(requestID.uuidString)
                  reason: \(reason)
                """)
                print("""
                [TuringDoorPortal] full exterior load started
                  requestID: \(requestID.uuidString)
                  doorState: \(self.battleDoorState.rawValue)
                """)
                try await self.ensurePortalWorldLoaded(reason: "doorOpen.\(reason)")
                try Task.checkCancellation()
                guard self.portalRequiredByDoorState,
                      self.portalLifecycle.activeLease == lease,
                      let animationController = self.animationController else {
                    return
                }
                self.portalLifecycle.markClosedReady(lease: lease)
                self.updateInteractionPresentation()
                print("""
                [TuringDoorPortal] full exterior ready behind closed door
                  requestID: \(requestID.uuidString)
                  leaseID: \(lease.id.uuidString)
                  doorState: \(self.battleDoorState.rawValue)
                """)
                self.portalLifecycle.markOpening(lease: lease)
                self.updateInteractionPresentation()
                try await animationController.openAndWait(reason: reason)
                guard self.portalLifecycle.activeLease == lease else { return }
                self.portalLifecycle.markOpen(lease: lease)
                self.updateInteractionPresentation()
                self.assertDoorPortalInvariant(context: "manualOpen.\(reason)")
            } catch is CancellationError {
                self.portalRequiredByDoorState = false
                self.reconcilePortalDemand(reason: "doorOpenCancelled.\(reason)")
                self.portalLifecycle.recoverClosedUnloaded()
                self.storyInteractionLease = nil
                self.updateInteractionPresentation()
                if let claimedStoryLease {
                    await StoryInteractionArbiter.shared.release(
                        claimedStoryLease,
                        reason: "doorOpenCancelled.\(reason)"
                    )
                }
            } catch {
                self.portalRequiredByDoorState = false
                self.reconcilePortalDemand(reason: "doorOpenFailed.\(reason)")
                self.portalLifecycle.recoverClosedUnloaded()
                self.storyInteractionLease = nil
                self.updateInteractionPresentation()
                if let claimedStoryLease {
                    await StoryInteractionArbiter.shared.release(
                        claimedStoryLease,
                        reason: "doorOpenFailed.\(reason)"
                    )
                }
                print("""
                [TuringDoorPortal] ERROR open blocked because exterior failed to load
                  reason: \(reason)
                  error: \(error.localizedDescription)
                """)
            }
        }
    }

    private func requestBattleDoorOpen(
        ownerID: UUID,
        reason: String
    ) {
        guard portalOpenRequestTask == nil,
              portalTransitionTask == nil else {
            print(
                "[TuringDoorBattle] duplicate player open ignored ownerID=\(ownerID.uuidString) reason=\(reason)"
            )
            return
        }

        portalTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.portalTransitionTask = nil }

            do {
                let snapshot = await StoryInteractionArbiter.shared
                    .currentSnapshot()
                guard snapshot.exclusiveOwner == .battle(
                    battleInstanceID: ownerID
                ), snapshot.capabilities.contains(.doorOpen) else {
                    throw StoryInteractionClaimError.staleLease
                }

                try await self.acquireBattlePortal(
                    ownerID: ownerID,
                    reason: "playerDoorOpen.\(reason)"
                )
                try await self.openForBattle(
                    ownerID: ownerID,
                    reason: "playerDoorOpen.\(reason)"
                )
                print("""
                [TuringDoorBattle] player opened door during Battle01
                  ownerID: \(ownerID.uuidString)
                  doorState: \(self.battleDoorState.rawValue)
                  reason: \(reason)
                """)
            } catch is CancellationError {
                return
            } catch {
                if self.battleDoorState == .closed {
                    self.setBattleInteractionLocked(
                        false,
                        ownerID: ownerID,
                        reason: "playerDoorOpenFailed.\(reason)"
                    )
                }
                print("""
                [TuringDoorBattle] ERROR player open failed during Battle01
                  ownerID: \(ownerID.uuidString)
                  doorState: \(self.battleDoorState.rawValue)
                  reason: \(reason)
                  error: \(error.localizedDescription)
                """)
            }
        }
    }

    private func requestPlayerDoorClose(reason: String) {
        guard portalTransitionTask == nil,
              let storyLease = storyInteractionLease,
              let lease = portalLifecycle.activeLease,
              lease.owner == .player else {
            return
        }

        portalTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.portalTransitionTask = nil }
            do {
                try await StoryInteractionArbiter.shared.requireCurrent(storyLease)
                try await self.closeDoorAndUnload(
                    lease: lease,
                    reason: "player.\(reason)"
                )
                self.storyInteractionLease = nil
                await StoryInteractionArbiter.shared.updateDoorState(
                    .closedUnloaded,
                    reason: "manualClose.\(reason)"
                )
                await StoryInteractionArbiter.shared.release(
                    storyLease,
                    reason: "manualDoorClosedAndUnloaded.\(reason)"
                )
            } catch {
                switch self.battleDoorState {
                case .closed:
                    self.portalRequiredByDoorState = false
                    self.unloadPortalWorld(
                        reason: "manualCloseFailureButDoorClosed.\(reason)"
                    )
                    self.portalLifecycle.finishUnloaded(lease: lease)
                    self.storyInteractionLease = nil
                    await StoryInteractionArbiter.shared.updateDoorState(
                        .closedUnloaded,
                        reason: "manualCloseRecovered.\(reason)"
                    )
                    await StoryInteractionArbiter.shared.release(
                        storyLease,
                        reason: "manualCloseRecovered.\(reason)"
                    )
                case .opening:
                    self.portalLifecycle.markOpening(lease: lease)
                case .open:
                    self.portalLifecycle.markOpen(lease: lease)
                case .closing:
                    self.portalLifecycle.markClosing(lease: lease)
                }
                self.updateInteractionPresentation()
                print("""
                [TuringDoorPortal] ERROR manual close failed
                  leaseID: \(lease.id.uuidString)
                  reason: \(reason)
                  portalRetained: \(self.battlePortalFullExteriorResident)
                  error: \(error.localizedDescription)
                """)
            }
        }
    }

    private func closeDoorAndUnload(
        lease: TuringStoryDoorPortalLease,
        reason: String
    ) async throws {
        guard portalLifecycle.activeLease == lease,
              let animationController else {
            return
        }

        portalOpenRequestTask?.cancel()
        portalOpenRequestTask = nil
        portalLoadTask?.cancel()
        if let portalLoadTask {
            _ = try? await portalLoadTask.value
        }
        self.portalLoadTask = nil
        portalRequiredByDoorState = true
        portalLifecycle.markClosing(lease: lease)
        updateInteractionPresentation()
        print("""
        [TuringDoorPortal] closing started
          leaseID: \(lease.id.uuidString)
          reason: \(reason)
        """)

        try await animationController.closeAndWait(reason: reason)
        guard animationController.state == .closed,
              portalLifecycle.activeLease == lease else {
            throw BundleError.noPlacement
        }
        portalLifecycle.markClosedReady(lease: lease)
        print("""
        [TuringDoorPortal] closing completed
          leaseID: \(lease.id.uuidString)
          closeAnimationCompleted: true
          closeSFXActualCompletion: true
        """)

        let requestID = UUID()
        portalLifecycle.markUnloading(requestID: requestID, lease: lease)
        portalRequiredByDoorState = false
        updateInteractionPresentation()
        unloadPortalWorld(reason: reason, requestID: requestID)
        portalLifecycle.finishUnloaded(lease: lease)
        updateInteractionPresentation()
        assertDoorPortalInvariant(context: "closeAndUnload.\(reason)")
    }

    private func ensurePortalWorldLoaded(reason: String) async throws {
        if portalWorldLoaded {
            guard isFullExteriorLoaded else {
                throw TuringRuntimeError.invalidConfig(
                    "Door exterior reported loaded without its portal IBL."
                )
            }
            return
        }
        if let portalLoadTask {
            try await portalLoadTask.value
            guard portalWorldLoaded else {
                throw BundleError.noPlacement
            }
            return
        }
        guard let placement, anchors != nil else {
            throw BundleError.noPlacement
        }

        let atmosphere = activeAtmosphere
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.portalResourceLoader.populateFullExterior(
                portalWorld: self.portalWorldRoot,
                atmosphere: atmosphere,
                placement: placement
            )
            try Task.checkCancellation()
            guard self.portalDemandActive else {
                self.unloadPortalWorld(reason: "demandEndedDuringLoad.\(reason)")
                throw CancellationError()
            }
            if let anchors = self.anchors {
                try await self.rehydratePortalOnlyEntitiesIfNeeded(
                    anchors: anchors,
                    reason: reason
                )
                try Task.checkCancellation()
                self.installPortalOnlyEntities(anchors: anchors)
                self.setEnabledRecursively(anchors.portalPlane, isEnabled: true)
            }
            self.portalWorldLoaded = true
            self.assertDoorPortalInvariant(context: "exteriorLoaded.\(reason)")
            print("""
            [TuringDoorPortal] exterior loaded
              atmosphere: \(atmosphere.rawValue)
              reason: \(reason)
              activeBattleOwnerCount: \(self.battlePortalOwnerIDs.count)
              doorState: \(self.battleDoorState.rawValue)
            """)
        }
        portalLoadTask = task
        do {
            try await task.value
            portalLoadTask = nil
        } catch {
            portalLoadTask = nil
            if portalDemandActive == false {
                unloadPortalWorld(reason: "loadFailedWithoutDemand.\(reason)")
            }
            throw error
        }
    }

    private var portalDemandActive: Bool {
        portalRequiredByDoorState || battlePortalOwnerIDs.isEmpty == false
    }

    private func doorAnimationStateChanged(
        _ state: TuringStoryDoorAnimationController.DoorState
    ) {
        let lease = portalLifecycle.activeLease
        switch state {
        case .closed:
            if let lease,
               portalWorldLoaded {
                portalLifecycle.markClosedReady(lease: lease)
            } else if portalWorldLoaded == false {
                portalLifecycle.recoverClosedUnloaded()
            }
        case .opening:
            portalRequiredByDoorState = true
            if let lease {
                portalLifecycle.markOpening(lease: lease)
            }
        case .open:
            portalRequiredByDoorState = true
            if let lease {
                portalLifecycle.markOpen(lease: lease)
            }
            assertDoorPortalInvariant(context: "doorState.open")
        case .closing:
            portalRequiredByDoorState = true
            if let lease {
                portalLifecycle.markClosing(lease: lease)
            }
        }
        updateInteractionPresentation()
    }

    private func reconcilePortalDemand(reason: String) {
        guard portalDemandActive == false else { return }
        portalLoadTask?.cancel()
        portalLoadTask = nil
        unloadPortalWorld(reason: reason)
    }

    private func unloadPortalWorld(
        reason: String,
        requestID: UUID = UUID()
    ) {
        guard portalDemandActive == false else { return }
        guard battleDoorState == .closed else {
            print("""
            [TuringDoorPortal] exterior unload refused
              requestID: \(requestID.uuidString)
              reason: \(reason)
              doorState: \(battleDoorState.rawValue)
              fullExteriorRetained: true
            """)
            return
        }
        print("""
        [TuringDoorPortal] exterior unload started
          requestID: \(requestID.uuidString)
          reason: \(reason)
          doorClosed: true
        """)
        if let anchors {
            setEnabledRecursively(anchors.portalPlane, isEnabled: false)
            for record in anchors.portalOnlyEntities {
                guard let source = record.source else { continue }
                removePortalIBLReceiversRecursively(from: source)
                source.removeFromParent()
                record.source = nil
            }
        }
        let removedChildCount = portalWorldRoot.children.count
        PortalHDRIDomeRuntimeDiagnostics.logRemoval(
            from: portalWorldRoot,
            reason: reason
        )
        portalWorldRoot.children.removeAll()
        portalWorldRoot.components.set(WorldComponent())
        portalWorldLoaded = false
        portalResourceLoader.clearPreparedAndCachedExterior(
            portalWorld: portalWorldRoot,
            reason: reason
        )
        TuringMemoryBudgetProbe.log(
            label: "doorExteriorUnloaded.\(requestID.uuidString)"
        )
        print("""
        [TuringDoorPortal] exterior unloaded
          requestID: \(requestID.uuidString)
          reason: \(reason)
          removedPortalWorldChildren: \(removedChildCount)
          retainedPortalOnlySources: \(anchors?.portalOnlyEntities.filter { $0.source != nil }.count ?? 0)
          doorState: \(battleDoorState.rawValue)
          activeBattleOwnerCount: \(battlePortalOwnerIDs.count)
          fallbackBackdrop: none
        """)
    }

    private func removePortalIBLReceiversRecursively(from entity: Entity) {
        entity.components.remove(ImageBasedLightReceiverComponent.self)
        for child in entity.children {
            removePortalIBLReceiversRecursively(from: child)
        }
    }

    private func prunePortalOnlyEntitiesFromPassthrough(
        in bundleRoot: Entity
    ) {
        for entityName in Self.portalOnlyEntityNames {
            guard let source = bundleRoot.turingDoorFindEntity(named: entityName) else {
                print(
                    """
                    [TuringDoorPortal] portal-only entity missing
                      entity: \(entityName)
                      action: passthrough_prune_skipped
                      required: false
                    """
                )
                continue
            }

            source.isEnabled = false

            print(
                """
                [TuringDoorPortal] portal-only entity pruned from passthrough render
                  entity: \(entityName)
                  action: source_entity_disabled
                  passthroughPreserved: frame_and_panel
                  portalWorldInstallExpected: true
                """
            )
        }
    }

    private func installPortalOnlyEntities(
        anchors: Anchors
    ) {
        let portalIBLEntity = firstPortalIBLEntity(in: portalWorldRoot)
        for record in anchors.portalOnlyEntities {
            guard let source = record.source else {
                print("[TuringDoorPortal] ERROR portal-only source unavailable entity=\(record.name)")
                continue
            }
            source.removeFromParent()
            setEnabledRecursively(source, isEnabled: true)
            portalWorldRoot.addChild(source)
            source.setTransformMatrix(
                record.authoredPortalTransform,
                relativeTo: portalWorldRoot
            )
            let receiverCount: Int
            if let portalIBLEntity {
                receiverCount = attachPortalIBLReceiversRecursively(
                    under: source,
                    iblEntity: portalIBLEntity
                )
            } else {
                receiverCount = 0
            }

            print(
                """
                [TuringDoorPortal] portal-only entity moved into portal world
                  source: \(source.name)
                  parent: TuringStoryDoorPortalWorldRoot
                  transformBasis: cached_authored_source_relative_to_portalWorldRoot
                  duplicateEntityGraph: false
                  portalIBLEntity: \(portalIBLEntity?.name ?? "missing")
                  portalIBLReceiverCount: \(receiverCount)
                """
            )
        }
    }

    private func rehydratePortalOnlyEntitiesIfNeeded(
        anchors: Anchors,
        reason: String
    ) async throws {
        let missing = anchors.portalOnlyEntities.filter { $0.source == nil }
        guard missing.isEmpty == false else { return }
        guard let url = doorBundleURL() else {
            throw BundleError.missingUSDZ("turing_story_door_bundle_v1.usdz")
        }

        let reloadRoot = try await Entity(contentsOf: url)
        try Task.checkCancellation()
        let resolved = try missing.map { record -> (PortalOnlyEntity, Entity) in
            guard let source = reloadRoot.turingDoorFindEntity(named: record.name) else {
                throw BundleError.missingRequiredEntity(record.name)
            }
            return (record, source)
        }
        for (record, source) in resolved {
            source.removeFromParent()
            setEnabledRecursively(source, isEnabled: false)
            record.source = source
        }

        print("""
        [TuringDoorPortal] portal-only authored entities rehydrated
          reason: \(reason)
          sourceUSDZ: \(url.lastPathComponent)
          entityCount: \(missing.count)
          entities: \(missing.map(\.name).joined(separator: ","))
          passthroughAttached: false
        """)
    }

    private func doorBundleURL() -> URL? {
        Bundle.main.url(
            forResource: "turing_story_door_bundle_v1",
            withExtension: "usdz",
            subdirectory: "Turing/Props"
        ) ?? Bundle.main.url(
            forResource: "turing_story_door_bundle_v1",
            withExtension: "usdz"
        )
    }

    private func firstPortalIBLEntity(
        in root: Entity
    ) -> Entity? {
        if root.components[ImageBasedLightComponent.self] != nil {
            return root
        }
        for child in root.children {
            if let found = firstPortalIBLEntity(in: child) {
                return found
            }
        }
        return nil
    }

    @discardableResult
    private func attachPortalIBLReceiversRecursively(
        under root: Entity,
        iblEntity: Entity
    ) -> Int {
        root.components.set(
            ImageBasedLightReceiverComponent(
                imageBasedLight: iblEntity
            )
        )
        return root.children.reduce(1) { count, child in
            count + attachPortalIBLReceiversRecursively(
                under: child,
                iblEntity: iblEntity
            )
        }
    }

    private func setEnabledRecursively(
        _ entity: Entity,
        isEnabled: Bool
    ) {
        entity.isEnabled = isEnabled

        for child in entity.children {
            setEnabledRecursively(
                child,
                isEnabled: isEnabled
            )
        }
    }

    private func installAnimationController(
        anchors: Anchors
    ) {
        animationController = TuringStoryDoorAnimationController(
            hingePivot: anchors.hingePivot,
            audioEmitter: anchors.audioEmitter,
            openYawDegrees: config.defaultOpenYawDegrees,
            openDuration: config.openDurationSeconds,
            closeDuration: config.closeDurationSeconds,
            onStateChanged: { [weak self] state in
                self?.doorAnimationStateChanged(state)
            }
        )
    }

    private func updateInteractionPresentation() {
        let mapped: StoryDoorLifecycleState
        switch portalLifecycle.state {
        case .closedUnloaded:
            mapped = .closedUnloaded
        case .loading:
            mapped = .loading
        case .closedReady:
            mapped = .closedReady
        case .opening:
            mapped = .opening
        case .open:
            mapped = .open
        case .closing:
            mapped = .closing
        case .unloading:
            mapped = .unloading
        case .failed:
            mapped = .failed
        }
        Task {
            await StoryInteractionArbiter.shared.updateDoorState(
                mapped,
                reason: "doorLifecycle"
            )
        }
    }

    private func assertDoorPortalInvariant(context: String) {
        let doorIsOpen = battleDoorState == .open
        let portalIsReady = isFullExteriorLoaded
        if doorIsOpen && portalIsReady == false {
            assertionFailure(
                "Door is open without the full exterior portal: \(context)"
            )
            print("""
            [TuringDoorPortal] ERROR lifecycle invariant violated
              context: \(context)
              doorState: open
              fullExteriorLoaded: false
              fallbackBackdrop: none
            """)
        }
    }

    private func choosePlacement(
        wallManager: WallPlaneManager,
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>
    ) -> TuringStoryDoorBundlePlacement? {
        let width = config.defaultWidthMeters
        let height = config.defaultHeightMeters
        let visualHeight = loadedVisualHeight
        let walls = wallManager.wallCandidates.values
            .filter {
                $0.width >= width
            }

        if walls.isEmpty {
            print(
                """
                [TuringDoorBundle] no wall candidates wide enough
                  requiredWidth: \(width)
                  occupancyHeight: \(height)
                  visualHeight: \(visualHeight)
                  scannedWallCount: \(wallManager.wallCandidates.count)
                """
            )
        }

        var best: (placement: TuringStoryDoorBundlePlacement, score: Float)?

        for wall in walls {
            guard let floor = wallManager.bestFloorCandidate(near: wall) else {
                print(
                    """
                    [TuringDoorBundle] candidate rejected
                      wallID: \(wall.id)
                      reason: missing_floor_candidate_for_floor_snap
                    """
                )
                continue
            }
            let desiredWorldY =
                floor.worldY +
                TuringStoryDoorBundleTuning.minBottomClearanceMeters +
                height * 0.5

            let desiredLocalY: Float
            if abs(wall.up.y) > 0.05 {
                desiredLocalY = (desiredWorldY - wall.center.y) / wall.up.y
            } else {
                desiredLocalY = 0
            }

            let maxX = max(
                0,
                wall.width * 0.5 - width * 0.5 -
                    TuringStoryDoorBundleTuning.wallMarginMeters
            )
            let candidateXs: [Float] = [
                0,
                -maxX * 0.55,
                maxX * 0.55,
                -maxX,
                maxX
            ]

            for x in candidateXs {
                let placement = TuringStoryDoorBundlePlacement(
                    wallID: wall.id,
                    localX: x,
                    localY: desiredLocalY,
                    depthOffset: config.defaultDepthOffsetMeters,
                    width: width,
                    height: height,
                    floorWorldY: floor.worldY,
                    worldYawRadians: worldYawRadians(wall: wall)
                )
                let rect = turingDoorWallRect(for: placement)
                let expandedRect = rect.expanded(
                    by: config.occupancyPaddingMeters
                )

                if wall.height < height {
                    print(
                        """
                        [TuringDoorBundle] wall shorter than occupancy height; using floor snap
                          wallID: \(wall.id)
                          wallHeight: \(wall.height)
                          occupancyHeight: \(height)
                          visualHeight: \(visualHeight)
                          floorWorldY: \(floor.worldY)
                        """
                    )
                }

                if occupancyRegistry?.hasHardOverlap(
                    wallID: wall.id,
                    candidate: expandedRect,
                    candidateKind: .storyDoorBundle
                ) == true {
                    print(
                        """
                        [TuringDoorBundle] candidate rejected by wall occupancy
                          wallID: \(wall.id)
                          reason: overlaps_poster_or_portal_or_story_prop
                        """
                    )
                    continue
                }

                let toWall = turingDoorNormalizeSafe(
                    wall.center - playerPosition,
                    fallback: SIMD3<Float>(0, 0, -1)
                )
                let forward = turingDoorNormalizeSafe(
                    SIMD3<Float>(playerForward.x, 0, playerForward.z),
                    fallback: SIMD3<Float>(0, 0, -1)
                )
                let facingScore = max(
                    0,
                    simd_dot(toWall, forward)
                )
                let posterDistance = occupancyRegistry?.nearestDistance(
                    wallID: wall.id,
                    candidate: rect,
                    kinds: [.wallPoster]
                ) ?? Float.greatestFiniteMagnitude
                let portalDistance = occupancyRegistry?.nearestDistance(
                    wallID: wall.id,
                    candidate: rect,
                    kinds: [.hordePortal, .storyPortal]
                ) ?? Float.greatestFiniteMagnitude
                let walkieDistance = occupancyRegistry?.nearestDistance(
                    wallID: wall.id,
                    candidate: rect,
                    kinds: [.storyWalkieBundle]
                ) ?? Float.greatestFiniteMagnitude
                let windowDistance = occupancyRegistry?.nearestDistance(
                    wallID: wall.id,
                    candidate: rect,
                    kinds: [.storyWindowBundle]
                ) ?? Float.greatestFiniteMagnitude
                let score =
                    facingScore * 4.0 +
                    wall.stabilityScore * 2.0 +
                    min(1, posterDistance) *
                        TuringStoryDoorBundleTuning.posterAvoidanceWeight +
                    min(1, portalDistance) *
                        TuringStoryDoorBundleTuning.portalAvoidanceWeight +
                    min(1, walkieDistance) *
                        TuringStoryDoorBundleTuning.walkieAvoidanceWeight +
                    min(1, windowDistance) *
                        TuringStoryDoorBundleTuning.windowAvoidanceWeight -
                    abs(x) * 0.20

                if best == nil || score > best!.score {
                    best = (placement, score)
                }
            }
        }

        return best?.placement
    }

    private func worldTransform(
        placement: TuringStoryDoorBundlePlacement,
        wallManager: WallPlaneManager
    ) -> simd_float4x4? {
        guard let wall = wallManager.wallCandidateForPlacement(
            id: placement.wallID
        ) else {
            return nil
        }

        let position =
            wall.center +
            wall.right * placement.localX +
            wall.up * groundedRootLocalY(
                placement: placement,
                wall: wall
            ) +
            wall.normal * placement.depthOffset

        var matrix = matrix_identity_float4x4
        matrix.columns.0 = SIMD4<Float>(wall.right.x, wall.right.y, wall.right.z, 0)
        matrix.columns.1 = SIMD4<Float>(wall.up.x, wall.up.y, wall.up.z, 0)
        matrix.columns.2 = SIMD4<Float>(wall.normal.x, wall.normal.y, wall.normal.z, 0)
        matrix.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return matrix
    }

    private func registerOccupancy(
        placement: TuringStoryDoorBundlePlacement,
        semanticReservation: WallLocalRect? = nil
    ) {
        occupancyRegistry?.unregister(id: occupancyID)
        occupancyRegistry?.register(
            id: occupancyID,
            wallID: placement.wallID,
            kind: .storyDoorBundle,
            rect: semanticReservation ?? turingDoorWallRect(for: placement),
            padding: semanticReservation == nil ? config.occupancyPaddingMeters : 0,
            label: "Turing Story door portal bundle"
        )
    }

    private func logFloorSnapProof(
        placement: TuringStoryDoorBundlePlacement,
        wallManager: WallPlaneManager
    ) {
        guard let wall = wallManager.wallCandidateForPlacement(
            id: placement.wallID
        ) else {
            return
        }

        let rootPosition =
            wall.center +
            wall.right * placement.localX +
            wall.up * groundedRootLocalY(
                placement: placement,
                wall: wall
            ) +
            wall.normal * placement.depthOffset
        let visualBottomWorld =
            rootPosition +
            wall.up * loadedVisualMinY
        let floorWorldY = placement.floorWorldY

        print(
            """
            [TuringDoorBundle] floor snap proof
              rootOriginWorldY: \(rootPosition.y)
              visualBottomWorldY: \(visualBottomWorld.y)
              floorWorldY: \(floorWorldY.map { "\($0)" } ?? "nil")
              originClearanceMeters: \(floorWorldY.map { "\(rootPosition.y - $0)" } ?? "nil")
              bottomClearanceMeters: \(floorWorldY.map { "\(visualBottomWorld.y - $0)" } ?? "nil")
              expectedBottomClearanceMeters: \(TuringStoryDoorBundleTuning.minBottomClearanceMeters)
              floorSnapBasis: authored_origin
              visualMinY: \(loadedVisualMinY)
              visualMaxY: \(loadedVisualMaxY)
              visualCenterY: \(loadedVisualCenterY)
              assetImportScale: \(TuringStoryDoorBundleTuning.assetImportScale)
            """
        )
    }

    private func groundedRootLocalY(
        placement: TuringStoryDoorBundlePlacement,
        wall: WallCandidate
    ) -> Float {
        guard let floorWorldY = placement.floorWorldY,
              abs(wall.up.y) > 0.05 else {
            return placement.localY - loadedVisualCenterY
        }

        let targetBottomWorldY =
            floorWorldY +
            TuringStoryDoorBundleTuning.minBottomClearanceMeters

        return (targetBottomWorldY - wall.center.y) / wall.up.y
    }

    private func worldYawRadians(
        wall: WallCandidate
    ) -> Float {
        let wallForward = turingDoorNormalizeSafe(
            wall.normal,
            fallback: SIMD3<Float>(0, 0, 1)
        )
        return atan2(
            wallForward.x,
            wallForward.z
        )
    }
    var adjustmentPropID: TuringStoryPropID { .door }

    var adjustmentRoot: Entity { root }

    var adjustmentOccupancyID: UUID { occupancyID }

    func currentPlacementSlot() -> TuringStoryRuntimeSlot? {
        committedAdjustmentSlot
    }

    func adjustmentWorldTransform(
        for placement: TuringStoryDoorBundlePlacement
    ) throws -> simd_float4x4 {
        guard let wallManager else {
            throw TuringStoryPlacementAdjustmentError.missingWallManager
        }
        guard let transform = worldTransform(
            placement: placement,
            wallManager: wallManager
        ) else {
            throw TuringStoryPlacementAdjustmentError
                .placementTransformUnavailable(
                    slotID: "door:\(placement.wallID)"
                )
        }
        return transform
    }

    func adoptCommittedAdjustmentSlot(
        _ slot: TuringStoryRuntimeSlot
    ) throws {
        guard slot.propID == .door,
              case .door = slot.placement else {
            throw TuringStoryPlacementAdjustmentError.wrongPlacementType(
                expected: .door,
                slotID: slot.slotID
            )
        }
        committedAdjustmentSlot = slot
        committedAdjustmentTransform = root.transformMatrix(relativeTo: nil)
    }

    func previewPlannedPlacement(
        _ slot: TuringStoryRuntimeSlot,
        duration: TimeInterval
    ) {
        guard slot.propID == .door,
              case .door = slot.placement else {
            print(
                "[TuringPlacementAdjust] door preview rejected slot=\(slot.slotID) reason=wrongPlacementType"
            )
            return
        }
        root.move(
            to: Transform(matrix: slot.worldTransform),
            relativeTo: nil,
            duration: duration,
            timingFunction: .easeInOut
        )
    }

    func commitAdjustedPlacement(
        _ slot: TuringStoryRuntimeSlot
    ) throws {
        guard slot.propID == .door,
              case .door(let adjusted) = slot.placement else {
            throw TuringStoryPlacementAdjustmentError.wrongPlacementType(
                expected: .door,
                slotID: slot.slotID
            )
        }
        guard occupancyRegistry != nil else {
            throw TuringStoryPlacementAdjustmentError
                .occupancyRegistrationFailed(.door)
        }

        root.setTransformMatrix(slot.worldTransform, relativeTo: nil)
        root.isEnabled = true
        placement = adjusted
        isPlaced = true
        registerOccupancy(
            placement: adjusted,
            semanticReservation: slot.semanticReservation
        )
        committedAdjustmentTransform = slot.worldTransform
        committedAdjustmentSlot = slot
    }

    func cancelPlacementPreview() {
        guard let committedAdjustmentTransform else {
            return
        }
        root.move(
            to: Transform(matrix: committedAdjustmentTransform),
            relativeTo: nil,
            duration: 0.18,
            timingFunction: .easeInOut
        )
    }
}

extension TuringStoryDoorBundleController:
    StoryInteractionSurfacePresenting
{
    func applyInteractionSnapshot(
        _ snapshot: StoryInteractionSnapshot
    ) {
        latestInteractionSnapshot = snapshot
        switch snapshot.doorPresentation {
        case .hidden:
            iconController.setPresentation(.hidden)
        case .open:
            iconController.setPresentation(.open)
        case .close:
            iconController.setPresentation(.close)
        }
    }
}

private extension Entity {
    func turingDoorFindEntity(
        named targetName: String
    ) -> Entity? {
        if name == targetName {
            return self
        }

        for child in children {
            if let found = child.turingDoorFindEntity(named: targetName) {
                return found
            }
        }

        return nil
    }

    func turingDoorFindEntity(
        containingNormalized token: String
    ) -> Entity? {
        if normalizedDoorEntityName.contains(token) {
            return self
        }

        for child in children {
            if let found = child.turingDoorFindEntity(
                containingNormalized: token
            ) {
                return found
            }
        }

        return nil
    }

    var normalizedDoorEntityName: String {
        name
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

private extension Data {
    func turingDoorZIPUInt16(
        at offset: Int
    ) -> UInt16 {
        guard offset + 2 <= count else {
            return 0
        }

        return UInt16(self[offset]) |
            (UInt16(self[offset + 1]) << 8)
    }

    func turingDoorZIPUInt32(
        at offset: Int
    ) -> UInt32 {
        guard offset + 4 <= count else {
            return 0
        }

        return UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}

private func turingDoorNormalizeSafe(
    _ v: SIMD3<Float>,
    fallback: SIMD3<Float>
) -> SIMD3<Float> {
    let length = simd_length(v)
    guard length > 0.00001 else {
        return fallback
    }

    return v / length
}
