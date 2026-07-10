import Foundation
import simd

private struct TuringStoryWallLayoutPreparedData: Sendable {
    let perimeter: TuringStoryRoomPerimeter
    let catalog: TuringStoryExactPlacementCatalog
    let feasibility: TuringStoryFeasibilityVector
    let posterSize: SIMD2<Float>
}

private struct TuringStoryWallLayoutPreparation: Sendable {
    func prepare(
        scanID: String,
        walls: [WallCandidate],
        floors: [FloorCandidate],
        occupancy: [WallPropOccupancyRecord],
        viewerPosition: SIMD3<Float>,
        viewerForward: SIMD3<Float>
    ) throws -> TuringStoryWallLayoutPreparedData {
        let frontageEvaluator = TuringStoryFloorFrontageEvaluator()
        let room = try TuringStoryRoomScanCleanser().cleanse(
            walls: walls,
            floors: floors,
            occupancy: occupancy,
            viewerPosition: viewerPosition,
            viewerForward: viewerForward,
            scanID: scanID
        )
        let perimeter = try TuringStoryRoomPerimeterBuilder().build(
            room: room,
            frontageEvaluator: frontageEvaluator
        )
        let catalog = try TuringStoryExactPlacementGenerator().generate(
            room: room,
            perimeter: perimeter,
            frontageEvaluator: frontageEvaluator
        )
        let feasibility = TuringStoryHotspotFeasibility().maximumLexicographicVector(
            catalog: catalog
        )
        let posterSize = perimeter.wallsClockwise.compactMap { wall -> SIMD2<Float>? in
            guard let raw = room.rawWallByID[wall.representativeWallUUID] else { return nil }
            return WallPosterMetrics.posterSize(for: raw)
        }.max { lhs, rhs in
            lhs.x * lhs.y < rhs.x * rhs.y
        } ?? SIMD2<Float>(0.72, 1.02)
        return TuringStoryWallLayoutPreparedData(
            perimeter: perimeter,
            catalog: catalog,
            feasibility: feasibility,
            posterSize: posterSize
        )
    }
}

@MainActor
final class TuringStoryWallLayoutCoordinator {
    enum State: String, Sendable {
        case idle, cleansing, planning, validating, preparingAssets, committing, complete, failed
    }

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    private let validator = TuringStoryHotspotLayoutValidator()
    private let compressor: TuringStoryPlacementHotspotCompressor
    private let planner: TuringStoryHotspotWallLayoutPlanner
    private let artifacts: TuringStoryHotspotDebugArtifacts

    private let doorController: TuringStoryDoorBundleController
    private let windowController: TuringStoryWindowBundleController
    private let walkieController: TuringStoryWalkieBundleController
    private let posterController: WallMountedPosterUIController
    private let onCommitted: @MainActor (String) -> Void
    private let onFailed: @MainActor (String, String) -> Void

    var isPlanningOrCommitting: Bool {
        switch state {
        case .cleansing, .planning, .validating, .preparingAssets, .committing: return true
        case .idle, .complete, .failed: return false
        }
    }

    init(
        doorController: TuringStoryDoorBundleController,
        windowController: TuringStoryWindowBundleController,
        walkieController: TuringStoryWalkieBundleController,
        posterController: WallMountedPosterUIController,
        onCommitted: @escaping @MainActor (String) -> Void = { _ in },
        onFailed: @escaping @MainActor (String, String) -> Void = { _, _ in }
    ) {
        let artifacts = TuringStoryHotspotDebugArtifacts()
        let compressor = TuringStoryPlacementHotspotCompressor()
        self.artifacts = artifacts
        self.compressor = compressor
        self.planner = TuringStoryHotspotWallLayoutPlanner(
            compressor: compressor,
            debugArtifacts: artifacts
        )
        self.doorController = doorController
        self.windowController = windowController
        self.walkieController = walkieController
        self.posterController = posterController
        self.onCommitted = onCommitted
        self.onFailed = onFailed
    }

    func planAndCommit(
        wallManager: WallPlaneManager,
        occupancyRegistry: WallPropOccupancyRegistry,
        viewerPosition: SIMD3<Float>,
        viewerForward: SIMD3<Float>,
        atmosphere: PortalHDRIAtmosphere,
        reason: String
    ) {
        guard task == nil else {
            print("[TuringWallHotspot] request coalesced state=\(state.rawValue)")
            return
        }
        let walls = Array(wallManager.wallCandidates.values)
        let floors = Array(wallManager.floorCandidates.values)
        let occupancy = Array(occupancyRegistry.recordsByID.values)
        let scanID = String(format: "%08X", UInt32.random(in: UInt32.min...UInt32.max))
        state = .cleansing
        print(
            "[TuringWallHotspot] snapshot frozen scanID=\(scanID) rawWalls=\(walls.count) rawFloors=\(floors.count) occupancy=\(occupancy.count)"
        )
        task = Task { @MainActor [weak self, weak wallManager] in
            guard let self, let wallManager else { return }
            defer { self.task = nil }
            await self.execute(
                scanID: scanID,
                walls: walls,
                floors: floors,
                occupancy: occupancy,
                wallManager: wallManager,
                viewerPosition: viewerPosition,
                viewerForward: viewerForward,
                atmosphere: atmosphere,
                reason: reason
            )
        }
    }

    func resetForRetry() {
        guard !isPlanningOrCommitting else { return }
        state = .idle
    }

    func cancel(reason: String) {
        task?.cancel()
        task = nil
        if isPlanningOrCommitting { state = .failed }
        print("[TuringWallHotspot] cancelled reason=\(reason)")
    }

    private func execute(
        scanID: String,
        walls: [WallCandidate],
        floors: [FloorCandidate],
        occupancy: [WallPropOccupancyRecord],
        wallManager: WallPlaneManager,
        viewerPosition: SIMD3<Float>,
        viewerForward: SIMD3<Float>,
        atmosphere: PortalHDRIAtmosphere,
        reason: String
    ) async {
        do {
            try Task.checkCancellation()
            let prepared = try await Task.detached(priority: .userInitiated) {
                try TuringStoryWallLayoutPreparation().prepare(
                    scanID: scanID,
                    walls: walls,
                    floors: floors,
                    occupancy: occupancy,
                    viewerPosition: viewerPosition,
                    viewerForward: viewerForward
                )
            }.value
            try Task.checkCancellation()
            let perimeter = prepared.perimeter
            let catalog = prepared.catalog
            let required = prepared.feasibility
            await artifacts.writePerimeter(perimeter)
            print(
                "[TuringWallHotspot] perimeter built perimeterWallCount=\(perimeter.wallsClockwise.count) closed=\(perimeter.isClosed) floorWorldY=\(perimeter.floorWorldY)"
            )

            await artifacts.writeExactSummary(catalog)
            let counts = Dictionary(uniqueKeysWithValues: TuringStoryPropID.allCases.map {
                ($0.rawValue, catalog.placements(for: $0).count)
            })
            print(
                "[TuringWallHotspot] exact placements generated door=\(counts["door"] ?? 0) window=\(counts["window"] ?? 0) walkieShelf=\(counts["walkieShelf"] ?? 0) poster=\(counts["poster"] ?? 0) serializedToFoundation=false"
            )

            print(
                "[TuringWallHotspot] feasibility computed requiredVector=\(required.compactArray.map(String.init).joined(separator: ","))"
            )
            let context = TuringStoryHotspotPlanningContext(
                perimeter: perimeter,
                catalog: catalog,
                feasibility: required,
                posterSize: prepared.posterSize
            )
            state = .planning
            let plannerResult = try await planner.plan(context: context)
            try Task.checkCancellation()
            let hotspotCounts = Dictionary(uniqueKeysWithValues: TuringStoryPropID.allCases.map {
                ($0.rawValue, plannerResult.atlas.hotspots(for: $0).count)
            })
            print(
                "[TuringWallHotspot] hotspots compressed door=\(hotspotCounts["door"] ?? 0) window=\(hotspotCounts["window"] ?? 0) walkieShelf=\(hotspotCounts["walkieShelf"] ?? 0) poster=\(hotspotCounts["poster"] ?? 0) total=\(plannerResult.atlas.hotspots.count)"
            )

            state = .validating
            let acceptedPlan = plannerResult.plan
            let validated = try validator.acceptPromptSelections(
                plan: acceptedPlan,
                context: context,
                atlas: plannerResult.atlas
            )
            await artifacts.writeAcceptedPlan(acceptedPlan)
            print(
                "[TuringWallHotspot] prompt plan accepted semanticGates=false spatialReplan=false overlapGate=false placementVector=\(validated.placementVector.compactArray.map(String.init).joined(separator: ","))"
            )

            state = .preparingAssets
            TuringMemoryBudgetProbe.log(label: "beforeStoryPropAssetPrepare")
            do {
                async let door: Void = doorController.prepareForPlannedPlacement()
                async let window: Void = windowController.prepareForPlannedPlacement()
                async let walkie: Void = walkieController.prepareForPlannedPlacement()
                _ = try await (door, window, walkie)
            } catch {
                throw TuringStoryHotspotLayoutError.assetPreparationFailed(error.localizedDescription)
            }
            TuringMemoryBudgetProbe.log(label: "afterStoryPropAssetPrepare")
            try Task.checkCancellation()
            state = .committing
            print("[TuringWallHotspot] commit started order=door,window,walkieShelf,poster")
            try await commit(validated, wallManager: wallManager, atmosphere: atmosphere)
            TuringMemoryBudgetProbe.log(label: "afterStoryPropCommit")
            state = .complete
            print("[TuringWallHotspot] layout committed scanID=\(scanID)")
            onCommitted(scanID)
        } catch is CancellationError {
            let failedStage = state.rawValue
            state = .failed
            await artifacts.writeFailure(scanID: scanID, stage: failedStage, reason: "cancelled")
        } catch {
            let failedStage = state.rawValue
            state = .failed
            await artifacts.writeFailure(
                scanID: scanID,
                stage: failedStage,
                reason: "\(reason): \(error.localizedDescription)"
            )
            print(
                "[TuringWallHotspot] failed scanID=\(scanID) stage=\(failedStage) error=\(error.localizedDescription) fallbackUsed=false"
            )
            onFailed(scanID, error.localizedDescription)
        }
    }

    private func commit(
        _ layout: TuringStoryValidatedHotspotLayout,
        wallManager: WallPlaneManager,
        atmosphere: PortalHDRIAtmosphere
    ) async throws {
        let oldDoor = doorController.placement
        let oldWindow = windowController.placement
        let oldWalkie = walkieController.placement
        let oldPoster = posterController.currentPlacementForStoryLayoutRollback()
        posterController.resetPlacement(reason: "hotspotLayoutCommit")
        do {
            let assigned = Set(layout.assignments.map(\.propID))
            if !assigned.contains(.door) { doorController.reset(reason: "hotspotUnplaced") }
            if !assigned.contains(.window) { windowController.reset(reason: "hotspotUnplaced") }
            if !assigned.contains(.walkieShelf) { walkieController.reset(reason: "hotspotUnplaced") }
            for assignment in layout.assignments.sorted(by: { $0.propID.priority < $1.propID.priority }) {
                let exact = assignment.placement
                switch assignment.propID {
                case .door:
                    try await doorController.commitPlannedPlacement(
                        doorPlacement(exact, wallManager: wallManager),
                        semanticReservation: exact.runtimeSemanticRect.wallLocalRect,
                        atmosphere: atmosphere
                    )
                case .window:
                    try await windowController.commitPlannedPlacement(
                        windowPlacement(exact, wallManager: wallManager),
                        semanticReservation: exact.runtimeSemanticRect.wallLocalRect,
                        atmosphere: atmosphere
                    )
                case .walkieShelf:
                    try await walkieController.commitPlannedPlacement(
                        walkiePlacement(exact),
                        semanticReservation: exact.runtimeSemanticRect.wallLocalRect
                    )
                case .poster:
                    guard posterController.commitPlannedStoryPlacement(
                        posterPlacement(exact),
                        semanticReservation: exact.runtimeSemanticRect.wallLocalRect
                    ) else { throw TuringStoryHotspotLayoutError.commitFailed("poster") }
                }
            }
        } catch {
            doorController.reset(reason: "hotspotRollback")
            windowController.reset(reason: "hotspotRollback")
            walkieController.reset(reason: "hotspotRollback")
            posterController.resetPlacement(reason: "hotspotRollback")
            if let oldDoor {
                try? await doorController.prepareForPlannedPlacement()
                try? await doorController.commitPlannedPlacement(
                    oldDoor,
                    semanticReservation: turingDoorWallRect(for: oldDoor),
                    atmosphere: atmosphere
                )
            }
            if let oldWindow {
                try? await windowController.prepareForPlannedPlacement()
                try? await windowController.commitPlannedPlacement(
                    oldWindow,
                    semanticReservation: turingWindowWallRect(for: oldWindow),
                    atmosphere: atmosphere
                )
            }
            if let oldWalkie {
                try? await walkieController.prepareForPlannedPlacement()
                try? await walkieController.commitPlannedPlacement(
                    oldWalkie,
                    semanticReservation: turingWalkieWallRect(for: oldWalkie)
                )
            }
            if let oldPoster {
                _ = posterController.commitPlannedStoryPlacement(
                    oldPoster,
                    semanticReservation: WallLocalRect(
                        minX: oldPoster.localX - oldPoster.width * 0.5,
                        minY: oldPoster.localY - oldPoster.height * 0.5,
                        maxX: oldPoster.localX + oldPoster.width * 0.5,
                        maxY: oldPoster.localY + oldPoster.height * 0.5
                    )
                )
            }
            throw error
        }
    }

    private func doorPlacement(
        _ exact: TuringStoryExactPlacement,
        wallManager: WallPlaneManager
    ) -> TuringStoryDoorBundlePlacement {
        let normal = wallManager.wallCandidates[exact.wallUUID]?.normal ?? SIMD3<Float>(0, 0, 1)
        return TuringStoryDoorBundlePlacement(
            wallID: exact.wallUUID,
            localX: exact.runtimeLocalX,
            localY: exact.runtimeLocalY,
            depthOffset: exact.depthOffset,
            width: exact.visualWidth,
            height: exact.visualHeight,
            floorWorldY: exact.floorWorldY,
            worldYawRadians: atan2(normal.x, normal.z)
        )
    }

    private func windowPlacement(
        _ exact: TuringStoryExactPlacement,
        wallManager: WallPlaneManager
    ) -> TuringStoryWindowBundlePlacement {
        let normal = wallManager.wallCandidates[exact.wallUUID]?.normal ?? SIMD3<Float>(0, 0, 1)
        return TuringStoryWindowBundlePlacement(
            wallID: exact.wallUUID,
            localX: exact.runtimeLocalX,
            localY: exact.runtimeLocalY,
            depthOffset: exact.depthOffset,
            width: exact.visualWidth,
            height: exact.visualHeight,
            floorWorldY: exact.floorWorldY,
            worldYawRadians: atan2(normal.x, normal.z)
        )
    }

    private func walkiePlacement(_ exact: TuringStoryExactPlacement) -> TuringStoryWallBundlePlacement {
        TuringStoryWallBundlePlacement(
            wallID: exact.wallUUID,
            localX: exact.runtimeLocalX,
            localY: exact.runtimeLocalY,
            depthOffset: exact.depthOffset,
            width: exact.visualWidth,
            height: exact.visualHeight,
            floorWorldY: exact.floorWorldY
        )
    }

    private func posterPlacement(_ exact: TuringStoryExactPlacement) -> WallPosterPlacement {
        WallPosterPlacement(
            wallID: exact.wallUUID,
            localX: exact.runtimeLocalX,
            localY: exact.runtimeLocalY,
            depthOffset: exact.depthOffset,
            width: exact.visualWidth,
            height: exact.visualHeight
        )
    }
}
