import Foundation
import simd

private struct TuringStoryWallLayoutPreparedData: Sendable {
    let catalog: TuringStoryExactPlacementCatalog
    let sliceMap: TuringStoryWallSliceMap
}

private struct TuringStoryWallLayoutPreparation: Sendable {
    func prepare(
        scanID: String,
        walls: [WallCandidate],
        floors: [FloorCandidate],
        occupancy: [WallPropOccupancyRecord],
        viewerPosition: SIMD3<Float>,
        viewerForward: SIMD3<Float>,
        spin: TuringStoryScanSpinResult
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
        let spinPerimeter = try TuringStorySpinOrderedPerimeterBuilder().build(
            perimeter: perimeter,
            spin: spin
        )
        let sliceMap = try TuringStoryWallSliceBuilder().build(
            perimeter: spinPerimeter,
            catalog: catalog
        )
        return TuringStoryWallLayoutPreparedData(
            catalog: catalog,
            sliceMap: sliceMap
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
    private let planner = TuringStoryWallSliceLayoutPlanner()
    private let resolver = TuringStoryWallSliceLayoutResolver()

    private let doorController: TuringStoryDoorBundleController
    private let windowController: TuringStoryWindowBundleController
    private let walkieController: TuringStoryWalkieBundleController
    private let posterController: WallMountedPosterUIController
    private let onCommitted: @MainActor (
        String,
        TuringStoryPlacementAdjustmentSeed
    ) -> Void
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
        onCommitted: @escaping @MainActor (
            String,
            TuringStoryPlacementAdjustmentSeed
        ) -> Void = { _, _ in },
        onFailed: @escaping @MainActor (String, String) -> Void = { _, _ in }
    ) {
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
        spin: TuringStoryScanSpinResult,
        atmosphere: PortalHDRIAtmosphere,
        reason: String
    ) {
        guard task == nil else {
            print("[TuringWallSlices] request coalesced state=\(state.rawValue)")
            return
        }
        let walls = Array(wallManager.wallCandidates.values)
        let floors = Array(wallManager.floorCandidates.values)
        let occupancy = Array(occupancyRegistry.recordsByID.values)
        let scanID = String(format: "%08X", UInt32.random(in: UInt32.min...UInt32.max))
        wallManager.retainPlacementWallSnapshot(
            walls,
            reason: "storyLayout.\(scanID)"
        )
        state = .cleansing
        print(
            "[TuringWallSlices] snapshot frozen scanID=\(scanID) rawWalls=\(walls.count) rawFloors=\(floors.count) occupancy=\(occupancy.count)"
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
                spin: spin,
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
        print("[TuringWallSlices] cancelled reason=\(reason)")
    }

    private func execute(
        scanID: String,
        walls: [WallCandidate],
        floors: [FloorCandidate],
        occupancy: [WallPropOccupancyRecord],
        wallManager: WallPlaneManager,
        viewerPosition: SIMD3<Float>,
        viewerForward: SIMD3<Float>,
        spin: TuringStoryScanSpinResult,
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
                    viewerForward: viewerForward,
                    spin: spin
                )
            }.value
            try Task.checkCancellation()
            let catalog = prepared.catalog
            let sliceMap = prepared.sliceMap
            print(
                "[TuringWallSlices] perimeter ordered direction=\(sliceMap.perimeter.spinDirection.rawValue) wallOrder=\(sliceMap.perimeter.walls.map { String($0.wallOrdinal) }.joined(separator: ",")) closed=\(sliceMap.perimeter.isClosed)"
            )
            print(
                "[TuringWallSlices] slice map built wallCount=\(sliceMap.perimeter.walls.count) sliceCount=\(sliceMap.slices.count) exactPlacementsSerializedToFoundation=false"
            )
            state = .planning
            let plannerResult = try await planner.plan(map: sliceMap)
            try Task.checkCancellation()
            state = .validating
            let resolved: TuringStoryResolvedSliceLayout
            do {
                resolved = try resolver.resolve(
                    plan: plannerResult.plan,
                    map: sliceMap,
                    catalog: catalog
                )
            } catch TuringStoryWallSliceError.invalidPlan(let issues) {
                let repaired = try await planner.repair(
                    previous: plannerResult,
                    issues: issues
                )
                resolved = try resolver.resolve(
                    plan: repaired,
                    map: sliceMap,
                    catalog: catalog
                )
            }

            state = .preparingAssets
            TuringMemoryBudgetProbe.log(label: "beforeStoryPropAssetPrepare")
            do {
                async let door: Void = doorController.prepareForPlannedPlacement()
                async let window: Void = windowController.prepareForPlannedPlacement()
                async let walkie: Void = walkieController.prepareForPlannedPlacement()
                _ = try await (door, window, walkie)
            } catch {
                throw TuringStoryWallSliceError.assetPreparationFailed(error.localizedDescription)
            }
            TuringMemoryBudgetProbe.log(label: "afterStoryPropAssetPrepare")
            try Task.checkCancellation()

            let adjustmentSeed = try TuringStoryPlacementCandidateCacheBuilder().build(
                scanID: scanID,
                catalog: catalog,
                sliceMap: sliceMap,
                resolvedLayout: resolved,
                wallManager: wallManager,
                doorController: doorController,
                windowController: windowController,
                walkieController: walkieController,
                posterController: posterController
            )

            try Task.checkCancellation()
            state = .committing
            print("[TuringWallSlices] commit started order=door,window,walkieShelf,poster")
            try await commit(resolved, wallManager: wallManager, atmosphere: atmosphere)
            TuringMemoryBudgetProbe.log(label: "afterStoryPropCommit")
            state = .complete
            print("[TuringWallSlices] layout committed scanID=\(scanID)")
            onCommitted(scanID, adjustmentSeed)
        } catch is CancellationError {
            state = .failed
        } catch {
            let failedStage = state.rawValue
            state = .failed
            print(
                "[TuringWallSlices] failed scanID=\(scanID) stage=\(failedStage) reason=\(reason) error=\(error.localizedDescription) fallbackUsed=false"
            )
            onFailed(scanID, error.localizedDescription)
        }
    }

    private func commit(
        _ layout: TuringStoryResolvedSliceLayout,
        wallManager: WallPlaneManager,
        atmosphere: PortalHDRIAtmosphere
    ) async throws {
        let oldDoor = doorController.placement
        let oldWindow = windowController.placement
        let oldWalkie = walkieController.placement
        let oldPoster = posterController.currentPlacementForStoryLayoutRollback()
        posterController.resetPlacement(reason: "sliceLayoutCommit")
        do {
            let assigned = Set(layout.assignments.map(\.propID))
            if !assigned.contains(.door) { doorController.reset(reason: "sliceUnplaced") }
            if !assigned.contains(.window) { windowController.reset(reason: "sliceUnplaced") }
            if !assigned.contains(.walkieShelf) { walkieController.reset(reason: "sliceUnplaced") }
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
                    ) else { throw TuringStoryWallSliceError.commitFailed("poster") }
                }
            }
        } catch {
            doorController.reset(reason: "sliceRollback")
            windowController.reset(reason: "sliceRollback")
            walkieController.reset(reason: "sliceRollback")
            posterController.resetPlacement(reason: "sliceRollback")
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
        let normal = wallManager.wallCandidateForPlacement(
            id: exact.wallUUID
        )?.normal ?? SIMD3<Float>(0, 0, 1)
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
        let normal = wallManager.wallCandidateForPlacement(
            id: exact.wallUUID
        )?.normal ?? SIMD3<Float>(0, 0, 1)
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
