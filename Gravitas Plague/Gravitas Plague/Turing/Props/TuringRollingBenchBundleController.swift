import Foundation
import RealityKit
import simd

@MainActor
final class TuringRollingBenchBundleController:
    TuringStoryAdjustablePlacementController,
    TuringStoryAdjustmentFrontEdgeProviding {
    enum BundleError: LocalizedError {
        case missingUSDZ(String)
        case missingRequiredEntity(String)
        case noWallManager
        case noPlacement
        case floorSnapFailed(Float)

        var errorDescription: String? {
            switch self {
            case .missingUSDZ(let value):
                return "Missing rolling-bench USDZ: \(value)"
            case .missingRequiredEntity(let value):
                return "Rolling-bench USDZ is missing required entity: \(value)"
            case .noWallManager:
                return "Missing wall manager for rolling-bench placement."
            case .noPlacement:
                return "Rolling bench is not prepared for placement."
            case .floorSnapFailed(let clearance):
                return "Rolling-bench floor snap failed. clearance=\(clearance)"
            }
        }
    }

    struct Anchors {
        let bundleRoot: Entity
        let cartRoot: Entity
        let crankRadioRoot: Entity
        let crankRadioIconAnchor: Entity
        let audioEmitter: Entity
        let hamReceiverRoot: Entity
        let hamReceiverIconAnchor: Entity
        let hamReceiverAudioEmitter: Entity
        let antigenRewardAnchor: Entity
    }

    let root = Entity()
    private(set) var anchors: Anchors?
    private(set) var placement: TuringRollingBenchBundlePlacement?
    private(set) var isPlaced = false
    private let crankRadioTuningLoops:
        TuringCrankRadioTuningLoopActor
    let radioController:
        TuringRollingBenchRadioController
    let crankRadioInteractionController:
        TuringStoryCrankRadioInteractionController
    let hamReceiverAudioController:
        TuringHamReceiverAudioController
    let hamReceiverInteractionController:
        TuringStoryHamReceiverInteractionController

    private weak var wallManager: WallPlaneManager?
    private weak var occupancyRegistry: WallPropOccupancyRegistry?
    private let occupancyID = UUID()
    private var loadedBundleRoot: Entity?
    private var loadedVisualMinY: Float = 0
    private var loadedVisualMaxY: Float = TuringRollingBenchTuning.expectedHeightMeters
    private var loadedVisualWidth: Float = TuringRollingBenchTuning.preferredReservationWidthMeters
    private var loadedVisualDepth: Float = TuringRollingBenchTuning.frontageDepthMeters
    private var loadedVisualMinZ: Float = -TuringRollingBenchTuning.frontageDepthMeters * 0.5
    private var loadedVisualMaxZ: Float = TuringRollingBenchTuning.frontageDepthMeters * 0.5
    private var committedAdjustmentTransform: simd_float4x4?
    private var committedAdjustmentSlot: TuringStoryRuntimeSlot?
    private var preparationTask: Task<Void, Error>?
    private var audioResourcesPrepared = false
    private var interactionInstalled = false

    init() {
        let tuningLoops =
            TuringCrankRadioTuningLoopActor.shared
        crankRadioTuningLoops = tuningLoops
        radioController =
            TuringRollingBenchRadioController(
                worker:
                    TuringRollingBenchRadioBedActor.shared,
                tuningLoops:
                    tuningLoops
            )
        crankRadioInteractionController =
            TuringStoryCrankRadioInteractionController(
                gate:
                    TuringFlowInteractionGateController
                        .shared,
                episodeFlow:
                    TuringEpisodeFlowController
                        .shared,
                dictation: nil,
                iconController: nil,
                tuningLoops:
                    tuningLoops,
                radioBed:
                    TuringRollingBenchRadioBedActor
                        .shared
            )
        hamReceiverAudioController =
            TuringHamReceiverAudioController(
                bed:
                    TuringHamReceiverBedActor.shared,
                tuningLoops:
                    TuringRandomTuningLoopActor
                        .hamReceiver
            )
        hamReceiverInteractionController =
            TuringStoryHamReceiverInteractionController(
                gate:
                    TuringFlowInteractionGateController
                        .shared,
                episodeFlow:
                    TuringEpisodeFlowController
                        .shared,
                dictation: nil,
                iconController: nil,
                tuningLoops:
                    TuringRandomTuningLoopActor
                        .hamReceiver,
                radioBed:
                    TuringHamReceiverBedActor
                        .shared
            )
        root.name = "TuringRollingBench_WorldRoot"
        root.isEnabled = false
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
        print("[TuringRollingBench] installed")
    }

    func prepareForPlannedPlacement() async throws {
        if let preparationTask {
            try await preparationTask.value
            return
        }
        if loadedBundleRoot != nil, anchors != nil, audioResourcesPrepared {
            return
        }

        let task = Task { @MainActor in
            try await self.prepareOnce()
        }
        preparationTask = task
        do {
            try await task.value
            preparationTask = nil
        } catch {
            preparationTask = nil
            throw error
        }
    }

    func commitPlannedPlacement(
        _ plannedPlacement: TuringRollingBenchBundlePlacement,
        semanticReservation: WallLocalRect
    ) async throws {
        guard let wallManager else { throw BundleError.noWallManager }
        if anchors == nil || loadedBundleRoot == nil {
            try await prepareForPlannedPlacement()
        }
        guard let anchors,
              let transform = worldTransform(
                placement: plannedPlacement,
                wallManager: wallManager
              ) else {
            throw BundleError.noPlacement
        }

        root.setTransformMatrix(transform, relativeTo: nil)
        let bottomY = visualBottomWorldY(
            transform: transform,
            wallID: plannedPlacement.wallID
        )
        let clearance = bottomY - plannedPlacement.floorWorldY
        guard abs(clearance) <= TuringRollingBenchTuning.floorSnapToleranceMeters else {
            throw BundleError.floorSnapFailed(clearance)
        }

        root.isEnabled = true
        placement = plannedPlacement
        isPlaced = true
        committedAdjustmentTransform = transform
        committedAdjustmentSlot = nil
        registerOccupancy(
            placement: plannedPlacement,
            semanticReservation: semanticReservation
        )

        if !interactionInstalled {
            try await radioController.install(
                emitter: anchors.audioEmitter
            )
            crankRadioInteractionController
                .crankRadioInstalled(
                iconAnchor: anchors.crankRadioIconAnchor,
                    crankRadioRoot: anchors.crankRadioRoot
            )
            try await hamReceiverAudioController.install(
                emitter:
                    anchors.hamReceiverAudioEmitter
            )
            let readiness =
                hamReceiverResourceReadiness()
            hamReceiverInteractionController
                .hamReceiverInstalled(
                    iconAnchor:
                        anchors.hamReceiverIconAnchor,
                    hamReceiverRoot:
                        anchors.hamReceiverRoot,
                    resourcesReady:
                        readiness.missing.isEmpty
                )
            if readiness.missing.isEmpty {
                hamReceiverInteractionController.bind(
                    .prologueHamReceiver,
                    initialState: .play,
                    reason: "prologueHamReceiverConfigured"
                )
            }
            print("""
            [TuringHamReceiver] authoring readiness
              ready: \(readiness.missing.isEmpty)
              missing: \(readiness.missing)
            """)
            interactionInstalled = true
        }

        print(
            """
            [TuringRollingBench] placement committed
              wallID: \(plannedPlacement.wallID)
              floorWorldY: \(plannedPlacement.floorWorldY)
              visualBottomWorldY: \(bottomY)
              bottomClearanceMeters: \(clearance)
              occupancyID: \(occupancyID)
              audioEmitter: \(anchors.audioEmitter.name)
              hamReceiverAudioEmitter: \(anchors.hamReceiverAudioEmitter.name)
            """
        )
    }

    func reset(reason: String) {
        preparationTask?.cancel()
        preparationTask = nil
        crankRadioInteractionController
            .crankRadioRemoved(reason: reason)
        hamReceiverInteractionController
            .hamReceiverRemoved(reason: reason)
        radioController.reset(reason: reason)
        hamReceiverAudioController.reset(
            reason: reason
        )
        interactionInstalled = false
        occupancyRegistry?.unregister(id: occupancyID)
        root.isEnabled = false
        placement = nil
        isPlaced = false
        committedAdjustmentTransform = nil
        committedAdjustmentSlot = nil
        print("[TuringRollingBench] reset reason=\(reason) retainedAsset=\(loadedBundleRoot != nil)")
    }

    func unload(reason: String) {
        reset(reason: reason)
        radioController.unload(reason: reason)
        hamReceiverAudioController.unload(
            reason: reason
        )
        root.children.removeAll()
        loadedBundleRoot = nil
        anchors = nil
        audioResourcesPrepared = false
        loadedVisualMinY = 0
        loadedVisualMaxY = TuringRollingBenchTuning.expectedHeightMeters
        loadedVisualWidth = TuringRollingBenchTuning.preferredReservationWidthMeters
        loadedVisualDepth = TuringRollingBenchTuning.frontageDepthMeters
        loadedVisualMinZ = -TuringRollingBenchTuning.frontageDepthMeters * 0.5
        loadedVisualMaxZ = TuringRollingBenchTuning.frontageDepthMeters * 0.5
        print("[TuringRollingBench] unloaded reason=\(reason)")
    }

    private func prepareOnce() async throws {
        if loadedBundleRoot == nil {
            let url = try bundleURL()
            let sourceBytes = (try? url.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize).map(Int64.init) ?? 0
            TuringMemoryBudgetProbe.log(label: "beforeRollingBenchLoad")
            let startedAt = Date()
            let loaded = try await Entity(contentsOf: url)
            let duration = Date().timeIntervalSince(startedAt)
            loaded.name = loaded.name.isEmpty
                ? TuringRollingBenchEntityName.canonicalBundleRoot
                : loaded.name
            root.children.removeAll()
            root.addChild(loaded)
            loadedBundleRoot = loaded
            TuringMemoryBudgetProbe.log(label: "afterRollingBenchLoad")
            print(
                """
                [TuringRollingBench] USDZ loaded
                  file: \(url.lastPathComponent)
                  sourceBytes: \(sourceBytes)
                  loadDurationSeconds: \(String(format: "%.3f", duration))
                  loadedOnce: true
                  importScale: 1.0
                  runtimeScale: \(TuringRollingBenchTuning.runtimeScale)
                """
            )
        }

        guard let loadedBundleRoot else { throw BundleError.noPlacement }
        anchors = try resolveAnchors(in: loadedBundleRoot)
        measureVisualBounds()
        TuringMemoryBudgetProbe.log(label: "afterRollingBenchAuthoredHierarchyResolved")
        if !audioResourcesPrepared {
            try await radioController.prepareResources()
            try await hamReceiverAudioController
                .prepareResources()
            audioResourcesPrepared = true
        }
    }

    private func bundleURL() throws -> URL {
        let url = Bundle.main.url(
            forResource: "turing_rolling_bench_bundle_v1",
            withExtension: "usdz",
            subdirectory: "Turing/Props"
        ) ?? Bundle.main.url(
            forResource: "turing_rolling_bench_bundle_v1",
            withExtension: "usdz"
        )
        guard let url else {
            throw BundleError.missingUSDZ("turing_rolling_bench_bundle_v1.usdz")
        }
        return url
    }

    private func resolveAnchors(in bundleRoot: Entity) throws -> Anchors {
        let cartRoot = try requireEntity(
            current: TuringRollingBenchEntityName.cartRoot,
            canonical: TuringRollingBenchEntityName.canonicalCartRoot,
            under: bundleRoot
        )
        let crankRadioRoot = try requireEntity(
            current: TuringRollingBenchEntityName.crankRadioRoot,
            canonical: TuringRollingBenchEntityName.canonicalCrankRadioRoot,
            under: bundleRoot
        )
        let crankRadioIconAnchor = try requireEntity(
            current: TuringRollingBenchEntityName.crankRadioIconAnchor,
            canonical: TuringRollingBenchEntityName.canonicalCrankRadioIconAnchor,
            under: bundleRoot
        )
        let hamReceiverRoot = try requireEntity(
            current:
                TuringRollingBenchEntityName
                    .hamReceiverRoot,
            canonical:
                TuringRollingBenchEntityName
                    .canonicalHamReceiverRoot,
            under: bundleRoot
        )
        let hamReceiverIconAnchor = try requireEntity(
            current:
                TuringRollingBenchEntityName
                    .hamReceiverIconAnchor,
            canonical:
                TuringRollingBenchEntityName
                    .canonicalHamReceiverIconAnchor,
            under: bundleRoot
        )
        let antigenRewardAnchor = try requireEntity(
            current: TuringRollingBenchEntityName.antigenRewardAnchor,
            canonical: TuringRollingBenchEntityName.antigenRewardAnchor,
            under: bundleRoot
        )
        let antigenHolsterRoot = try requireEntity(
            current: TuringRollingBenchEntityName.antigenHolsterRoot,
            canonical: TuringRollingBenchEntityName.antigenHolsterRoot,
            under: bundleRoot
        )
        let antigenVialRoots = try TuringRollingBenchEntityName.antigenVialRoots.map {
            try requireEntity(
                current: $0,
                canonical: $0,
                under: bundleRoot
            )
        }
        configureAuthoredAntigenPackage(
            anchor: antigenRewardAnchor,
            members: [antigenHolsterRoot] + antigenVialRoots
        )

        let authoredTopLevelChildren = bundleRoot.children.map { child in
            "\(child.name):enabled=\(child.isEnabled)"
        }.joined(separator: ",")

        let passthroughLighting = configurePassthroughLighting(
            in: bundleRoot
        )
        let emitter = makeAudioEmitter(
            named:
                TuringRollingBenchEntityName
                    .runtimeAudioEmitter,
            under: crankRadioRoot
        )
        let hamReceiverEmitter =
            makeAudioEmitter(
                named:
                    TuringRollingBenchEntityName
                        .runtimeHamReceiverAudioEmitter,
                under: hamReceiverRoot
            )

        print(
            """
            [TuringRollingBench] anchors resolved
              bundleRoot: \(bundleRoot.name)
              cartRoot: \(cartRoot.name)
              crankRadioRoot: \(crankRadioRoot.name)
              crankRadioIconAnchor: \(crankRadioIconAnchor.name)
              authoredHierarchyPreserved: true
              runtimeGeometryPruning: false
              authoredTopLevelChildren: \(authoredTopLevelChildren)
              proceduralAudioEmitter: \(emitter.name)
              hamReceiverRoot: \(hamReceiverRoot.name)
              hamReceiverIconAnchor: \(hamReceiverIconAnchor.name)
              hamReceiverAudioEmitter: \(hamReceiverEmitter.name)
              hamReceiverIconAnchorIsRootSibling: \(hamReceiverIconAnchor.parent === hamReceiverRoot.parent)
              antigenRewardAnchor: \(antigenRewardAnchor.name)
              antigenPackageMembers: \(([antigenHolsterRoot] + antigenVialRoots).map(\.name).joined(separator: ","))
              antigenInitiallyVisible: \(antigenRewardAnchor.isEnabled)
              automaticPassthroughLighting: true
              importedEnvironmentLightFound: \(passthroughLighting.lightFound)
              importedEnvironmentLightDisabled: \(passthroughLighting.lightDisabled)
              importedIBLReceiversRemoved: \(passthroughLighting.receiverCount)
            """
        )

        return Anchors(
            bundleRoot: bundleRoot,
            cartRoot: cartRoot,
            crankRadioRoot: crankRadioRoot,
            crankRadioIconAnchor: crankRadioIconAnchor,
            audioEmitter: emitter,
            hamReceiverRoot: hamReceiverRoot,
            hamReceiverIconAnchor:
                hamReceiverIconAnchor,
            hamReceiverAudioEmitter:
                hamReceiverEmitter,
            antigenRewardAnchor:
                antigenRewardAnchor
        )
    }

    private func configureAuthoredAntigenPackage(
        anchor: Entity,
        members: [Entity]
    ) {
        for member in members where member.parent !== anchor {
            member.setParent(
                anchor,
                preservingWorldTransform: true
            )
        }
        anchor.isEnabled = false

        print(
            """
            [TuringRollingBench] authored antigen package grouped
              anchor: \(anchor.name)
              members: \(members.map(\.name).joined(separator: ","))
              preservingAuthoredTransforms: true
              initiallyVisible: false
            """
        )
    }

    private func configurePassthroughLighting(
        in bundleRoot: Entity
    ) -> (lightFound: Bool, lightDisabled: Bool, receiverCount: Int) {
        // Remove USDZ-local IBL ownership so RealityKit uses the room's automatic passthrough lighting.
        let importedLight = bundleRoot.turingRollingBenchFindEntity(
            named: TuringRollingBenchEntityName.importedEnvironmentLight
        )
        importedLight?.isEnabled = false

        let receiverCount = removeImportedIBLReceiversRecursively(
            from: bundleRoot
        )
        return (
            lightFound: importedLight != nil,
            lightDisabled: importedLight?.isEnabled == false,
            receiverCount: receiverCount
        )
    }

    private func removeImportedIBLReceiversRecursively(
        from entity: Entity
    ) -> Int {
        var removedCount = 0
        if entity.components[ImageBasedLightReceiverComponent.self] != nil {
            entity.components.remove(ImageBasedLightReceiverComponent.self)
            removedCount = 1
        }
        return entity.children.reduce(removedCount) { count, child in
            count + removeImportedIBLReceiversRecursively(from: child)
        }
    }

    private func requireEntity(
        current: String,
        canonical: String,
        under root: Entity
    ) throws -> Entity {
        if let value = root.turingRollingBenchFindEntity(named: current) {
            return value
        }
        if let value = root.turingRollingBenchFindEntity(named: canonical) {
            return value
        }
        throw BundleError.missingRequiredEntity("\(current) / \(canonical)")
    }

    private func makeAudioEmitter(
        named: String,
        under parent: Entity
    ) -> Entity {
        if let existing = parent.turingRollingBenchFindEntity(
            named: named
        ) {
            return existing
        }
        let emitter = Entity()
        emitter.name = named
        emitter.position = .zero
        parent.addChild(emitter)
        return emitter
    }

    private func hamReceiverResourceReadiness()
        -> (missing: [String], ready: Bool)
    {
        var missing: [String] = []
        if Bundle.main.url(
            forResource:
                "pr-cat-eye-81-script01",
            withExtension: "mp3",
            subdirectory:
                "Turing/Audio/prerecordings"
        ) == nil {
            missing.append(
                "pr-cat-eye-81-script01.mp3"
            )
        }
        let cloneMetadataPath =
            "\(TuringCatEye81VoiceIdentity.cloneProfileResourcePath)/metadata.json"
        if (try? TuringResourceLoader.resourceURL(
            resourcePath: cloneMetadataPath
        )) == nil {
            missing.append(
                "cateye81_base_clone_v1.qwenclone"
            )
        }
        return (
            missing,
            missing.isEmpty
        )
    }

    private func measureVisualBounds() {
        let bounds = root.visualBounds(
            recursive: true,
            relativeTo: root,
            excludeInactive: false
        )
        let min = bounds.min
        let max = bounds.max
        guard min.x.isFinite, min.y.isFinite, min.z.isFinite,
              max.x.isFinite, max.y.isFinite, max.z.isFinite,
              max.y > min.y else {
            print("[TuringRollingBench] measured bounds unavailable; planning dimensions retained")
            return
        }
        loadedVisualMinY = min.y
        loadedVisualMaxY = max.y
        loadedVisualWidth = max.x - min.x
        loadedVisualDepth = max.z - min.z
        loadedVisualMinZ = min.z
        loadedVisualMaxZ = max.z
        let authoredHeight = loadedVisualMaxY - loadedVisualMinY
        let scale = TuringRollingBenchTuning.runtimeScale
        let scaledHeight = authoredHeight * scale
        let plausible = scaledHeight >= TuringRollingBenchTuning.minimumPlausibleHeightMeters &&
            scaledHeight <= TuringRollingBenchTuning.maximumPlausibleHeightMeters
        print(
            """
            [TuringRollingBench] measured bounds
              authoredWidthMeters: \(loadedVisualWidth)
              authoredHeightMeters: \(authoredHeight)
              authoredDepthMeters: \(loadedVisualDepth)
              scaledWidthMeters: \(loadedVisualWidth * scale)
              scaledHeightMeters: \(scaledHeight)
              scaledDepthMeters: \(loadedVisualDepth * scale)
              visualMinZ: \(loadedVisualMinZ)
              visualMaxZ: \(loadedVisualMaxZ)
              visualMinY: \(loadedVisualMinY)
              visualMaxY: \(loadedVisualMaxY)
              plausibleFourFootHeight: \(plausible)
              runtimeScaleApplied: \(scale)
            """
        )
    }

    private func worldTransform(
        placement: TuringRollingBenchBundlePlacement,
        wallManager: WallPlaneManager
    ) -> simd_float4x4? {
        guard let wall = wallManager.wallCandidateForPlacement(id: placement.wallID),
              abs(wall.up.y) > 0.05 else {
            return nil
        }
        let scale = TuringRollingBenchTuning.runtimeScale
        let groundedLocalY =
            (placement.floorWorldY - wall.center.y) / wall.up.y
            - loadedVisualMinY * scale
        let position = wall.center
            + wall.right * placement.localX
            + wall.up * groundedLocalY
            + wall.normal * placement.depthOffset
        var result = matrix_identity_float4x4
        result.columns.0 = SIMD4<Float>(
            wall.right.x * scale,
            wall.right.y * scale,
            wall.right.z * scale,
            0
        )
        result.columns.1 = SIMD4<Float>(
            wall.up.x * scale,
            wall.up.y * scale,
            wall.up.z * scale,
            0
        )
        result.columns.2 = SIMD4<Float>(
            wall.normal.x * scale,
            wall.normal.y * scale,
            wall.normal.z * scale,
            0
        )
        result.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return result
    }

    private func visualBottomWorldY(
        transform: simd_float4x4,
        wallID: UUID
    ) -> Float {
        guard let wall = wallManager?.wallCandidateForPlacement(id: wallID) else {
            return transform.columns.3.y
        }
        return transform.columns.3.y
            + wall.up.y
            * loadedVisualMinY
            * TuringRollingBenchTuning.runtimeScale
    }

    private func registerOccupancy(
        placement: TuringRollingBenchBundlePlacement,
        semanticReservation: WallLocalRect
    ) {
        occupancyRegistry?.unregister(id: occupancyID)
        occupancyRegistry?.register(
            id: occupancyID,
            wallID: placement.wallID,
            kind: .storyRollingBenchBundle,
            rect: semanticReservation,
            padding: 0,
            label: "Turing rolling bench bundle"
        )
    }

    var adjustmentPropID: TuringStoryPropID { .rollingBench }
    var adjustmentRoot: Entity { root }
    var adjustmentOccupancyID: UUID { occupancyID }

    func turingStoryAdjustmentFrontEdgeOffset(
        for propID: TuringStoryPropID
    ) -> Float {
        guard propID == .rollingBench else { return 0 }
        return loadedVisualMaxZ * TuringRollingBenchTuning.runtimeScale
    }

    func currentPlacementSlot() -> TuringStoryRuntimeSlot? {
        committedAdjustmentSlot
    }

    func adjustmentWorldTransform(
        for placement: TuringRollingBenchBundlePlacement
    ) throws -> simd_float4x4 {
        guard let wallManager else {
            throw TuringStoryPlacementAdjustmentError.missingWallManager
        }
        guard let transform = worldTransform(
            placement: placement,
            wallManager: wallManager
        ) else {
            throw TuringStoryPlacementAdjustmentError.placementTransformUnavailable(
                slotID: "rollingBench:\(placement.wallID)"
            )
        }
        return transform
    }

    func adoptCommittedAdjustmentSlot(_ slot: TuringStoryRuntimeSlot) throws {
        guard slot.propID == .rollingBench,
              case .rollingBench = slot.placement else {
            throw TuringStoryPlacementAdjustmentError.wrongPlacementType(
                expected: .rollingBench,
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
        guard slot.propID == .rollingBench,
              case .rollingBench = slot.placement else {
            return
        }
        root.move(
            to: Transform(matrix: slot.worldTransform),
            relativeTo: nil,
            duration: duration,
            timingFunction: .easeInOut
        )
    }

    func commitAdjustedPlacement(_ slot: TuringStoryRuntimeSlot) throws {
        guard slot.propID == .rollingBench,
              case .rollingBench(let adjusted) = slot.placement else {
            throw TuringStoryPlacementAdjustmentError.wrongPlacementType(
                expected: .rollingBench,
                slotID: slot.slotID
            )
        }
        guard occupancyRegistry != nil else {
            throw TuringStoryPlacementAdjustmentError
                .occupancyRegistrationFailed(.rollingBench)
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
        guard let committedAdjustmentTransform else { return }
        root.move(
            to: Transform(matrix: committedAdjustmentTransform),
            relativeTo: nil,
            duration: 0.18,
            timingFunction: .easeInOut
        )
    }

    func authoredRewardAnchor(named name: String) -> Entity? {
        guard name == TuringRollingBenchEntityName.antigenRewardAnchor else {
            return nil
        }
        return anchors?.antigenRewardAnchor
    }
}

private extension Entity {
    func turingRollingBenchFindEntity(named targetName: String) -> Entity? {
        if name == targetName { return self }
        for child in children {
            if let value = child.turingRollingBenchFindEntity(named: targetName) {
                return value
            }
        }
        return nil
    }
}
