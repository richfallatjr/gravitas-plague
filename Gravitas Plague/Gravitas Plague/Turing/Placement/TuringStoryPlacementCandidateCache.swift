import Foundation
import simd

struct TuringStoryPlacementCandidateCache: Sendable {
    private(set) var slotsByProp: [TuringStoryPropID: [TuringStoryRuntimeSlot]]

    init(
        slotsByProp: [TuringStoryPropID: [TuringStoryRuntimeSlot]]
    ) {
        self.slotsByProp = slotsByProp.mapValues { slots in
            slots.sorted(by: Self.routeSort)
        }
    }

    func slots(
        for propID: TuringStoryPropID
    ) -> [TuringStoryRuntimeSlot] {
        slotsByProp[propID] ?? []
    }

    func slot(
        propID: TuringStoryPropID,
        slotID: String
    ) -> TuringStoryRuntimeSlot? {
        slotsByProp[propID]?.first { $0.slotID == slotID }
    }

    private static func routeSort(
        lhs: TuringStoryRuntimeSlot,
        rhs: TuringStoryRuntimeSlot
    ) -> Bool {
        if lhs.wallOrdinal != rhs.wallOrdinal {
            return lhs.wallOrdinal < rhs.wallOrdinal
        }
        if abs(lhs.routeOrder - rhs.routeOrder) > 0.000_001 {
            return lhs.routeOrder < rhs.routeOrder
        }
        return lhs.slotID < rhs.slotID
    }
}

/// Pure merger kept separate from RealityKit materialization so candidate
/// retention, route sorting, and direct-projection insertion are unit-testable.
struct TuringStoryPlacementCandidateCacheAssembler: Sendable {
    func assemble(
        scanID: String,
        catalogSlotsByProp: [TuringStoryPropID: [TuringStoryRuntimeSlot]],
        resolvedInitialSlotsByProp: [TuringStoryPropID: TuringStoryRuntimeSlot]
    ) throws -> TuringStoryPlacementAdjustmentSeed {
        var merged: [TuringStoryPropID: [TuringStoryRuntimeSlot]] = [:]
        var initiallySelected: [TuringStoryPropID: String] = [:]

        for propID in TuringStoryPropID.allCases {
            var byID: [String: TuringStoryRuntimeSlot] = [:]
            for slot in catalogSlotsByProp[propID] ?? [] {
                byID[slot.slotID] = slot
            }

            if let initial = resolvedInitialSlotsByProp[propID] {
                // This is the required direct-projection path: if Foundation's
                // resolved initial slot was synthesized by the resolver and did
                // not exist in the exact catalog, retain it without moving the
                // already-committed prop.
                byID[initial.slotID] = initial
                initiallySelected[propID] = initial.slotID
            }

            let ordered = byID.values.sorted { lhs, rhs in
                if lhs.wallOrdinal != rhs.wallOrdinal {
                    return lhs.wallOrdinal < rhs.wallOrdinal
                }
                if abs(lhs.routeOrder - rhs.routeOrder) > 0.000_001 {
                    return lhs.routeOrder < rhs.routeOrder
                }
                return lhs.slotID < rhs.slotID
            }
            merged[propID] = ordered

            if let initialID = initiallySelected[propID],
                !ordered.contains(where: { $0.slotID == initialID })
            {
                throw TuringStoryPlacementAdjustmentError.missingInitialSlot(
                    propID: propID,
                    slotID: initialID
                )
            }
        }

        return TuringStoryPlacementAdjustmentSeed(
            scanID: scanID,
            candidatesByProp: merged,
            initiallySelectedSlotIDByProp: initiallySelected
        )
    }
}

/// The exact-placement catalog is generated before the perimeter is reduced to
/// the bounded spin route sent to Foundation Models. Candidates on walls that
/// are not in that route cannot be reached by the adjustment UI.
enum TuringStoryPlacementCatalogRouteFilter {
    static func placements(
        from catalogPlacements: [TuringStoryExactPlacement],
        routedWallIDs: Set<UUID>
    ) -> [TuringStoryExactPlacement] {
        catalogPlacements.filter { routedWallIDs.contains($0.wallUUID) }
    }
}

enum TuringStoryPlacementRouteMath {
    private static let epsilon: Float = 0.000_5

    /// Slice intervals and `TuringStoryExactPlacement.semanticRect` are both in
    /// canonical perimeter-wall coordinates. `runtimeSemanticRect` is in the
    /// representative live WallCandidate coordinates and must only be used for
    /// occupancy. Mixing those coordinate spaces reverses or drops candidates.
    static func coveredSlices(
        exact: TuringStoryExactPlacement,
        slices: [TuringStoryWallSlice]
    ) -> [TuringStoryWallSlice] {
        slices
            .filter {
                $0.representativeWallUUID == exact.wallUUID
                    && $0.localMaxX > exact.semanticRect.minX + epsilon
                    && $0.localMinX < exact.semanticRect.maxX - epsilon
            }
            .sorted { lhs, rhs in
                if lhs.wallOrdinal != rhs.wallOrdinal {
                    return lhs.wallOrdinal < rhs.wallOrdinal
                }
                return lhs.localSliceIndex < rhs.localSliceIndex
            }
    }

    static func routeOrder(
        localX: Float,
        wallOrdinal: Int,
        startLocalX: Float,
        endLocalX: Float
    ) -> Float {
        let denominator = max(0.001, abs(endLocalX - startLocalX))
        let progress = max(
            0,
            min(1, abs(localX - startLocalX) / denominator)
        )
        return Float(wallOrdinal) + progress
    }

    static func wrappedIndex(
        current: Int,
        direction: Int,
        count: Int
    ) -> Int {
        guard count > 0 else { return 0 }
        return (current + direction + count) % count
    }

    static func localX(
        worldXZ: SIMD2<Float>,
        wall: TuringStoryCanonicalWall
    ) -> Float {
        let point = SIMD3<Float>(worldXZ.x, wall.center.y, worldXZ.y)
        return simd_dot(point - wall.center, wall.right)
    }
}

@MainActor
struct TuringStoryPlacementCandidateCacheBuilder {
    func build(
        scanID: String,
        catalog: TuringStoryExactPlacementCatalog,
        sliceMap: TuringStoryWallSliceMap,
        resolvedLayout: TuringStoryResolvedSliceLayout,
        wallManager: WallPlaneManager,
        doorController: TuringStoryDoorBundleController,
        windowController: TuringStoryWindowBundleController,
        walkieController: TuringStoryWalkieBundleController,
        posterController: WallMountedPosterUIController
    ) throws -> TuringStoryPlacementAdjustmentSeed {
        guard sliceMap.perimeter.scanID == scanID else {
            throw TuringStoryPlacementAdjustmentError.scanMismatch(
                expected: scanID,
                actual: sliceMap.perimeter.scanID
            )
        }
        guard resolvedLayout.scanID == scanID else {
            throw TuringStoryPlacementAdjustmentError.scanMismatch(
                expected: scanID,
                actual: resolvedLayout.scanID
            )
        }

        let controllers = ControllerSet(
            door: doorController,
            window: windowController,
            walkie: walkieController,
            poster: posterController
        )

        let routedWallIDs = Set(
            sliceMap.perimeter.walls.map(\.representativeWallUUID)
        )
        let routedCatalogPlacements =
            TuringStoryPlacementCatalogRouteFilter.placements(
                from: catalog.placements,
                routedWallIDs: routedWallIDs
            )
        let skippedOutsideSpinRoute =
            catalog.placements.count - routedCatalogPlacements.count

        print(
            """
            [TuringPlacementAdjust] catalog filtered to spin route
              totalCatalogPlacements: \(catalog.placements.count)
              routedCatalogPlacements: \(routedCatalogPlacements.count)
              skippedOutsideSpinRoute: \(skippedOutsideSpinRoute)
              routedWallCount: \(routedWallIDs.count)
            """
        )

        var catalogSlotsByProp: [TuringStoryPropID: [TuringStoryRuntimeSlot]] = [:]
        for exact in routedCatalogPlacements {
            let slot = try materialize(
                exact: exact,
                forcedSliceIDs: nil,
                sliceMap: sliceMap,
                wallManager: wallManager,
                controllers: controllers
            )
            catalogSlotsByProp[exact.propID, default: []].append(slot)
        }

        var resolvedInitialSlotsByProp: [TuringStoryPropID: TuringStoryRuntimeSlot] = [:]
        for assignment in resolvedLayout.assignments {
            let slot = try materialize(
                exact: assignment.placement,
                forcedSliceIDs: assignment.sliceIDs,
                sliceMap: sliceMap,
                wallManager: wallManager,
                controllers: controllers
            )
            resolvedInitialSlotsByProp[assignment.propID] = slot
        }

        let seed = try TuringStoryPlacementCandidateCacheAssembler().assemble(
            scanID: scanID,
            catalogSlotsByProp: catalogSlotsByProp,
            resolvedInitialSlotsByProp: resolvedInitialSlotsByProp
        )

        print(
            """
            [TuringPlacementAdjust] cache ready
              scanID: \(scanID)
              doorCandidates: \(seed.candidatesByProp[.door]?.count ?? 0)
              windowCandidates: \(seed.candidatesByProp[.window]?.count ?? 0)
              shelfCandidates: \(seed.candidatesByProp[.walkieShelf]?.count ?? 0)
              posterCandidates: \(seed.candidatesByProp[.poster]?.count ?? 0)
            """
        )

        return seed
    }

    private struct ControllerSet {
        let door: TuringStoryDoorBundleController
        let window: TuringStoryWindowBundleController
        let walkie: TuringStoryWalkieBundleController
        let poster: WallMountedPosterUIController
    }

    private func materialize(
        exact: TuringStoryExactPlacement,
        forcedSliceIDs: [String]?,
        sliceMap: TuringStoryWallSliceMap,
        wallManager: WallPlaneManager,
        controllers: ControllerSet
    ) throws -> TuringStoryRuntimeSlot {
        guard
            let spinWall = sliceMap.perimeter.walls.first(where: {
                $0.representativeWallUUID == exact.wallUUID
            })
        else {
            throw TuringStoryPlacementAdjustmentError.missingWall(exact.wallUUID)
        }
        guard let liveWall = wallManager.wallCandidateForPlacement(
            id: exact.wallUUID
        ) else {
            throw TuringStoryPlacementAdjustmentError.missingWall(exact.wallUUID)
        }

        let covered = TuringStoryPlacementRouteMath.coveredSlices(
            exact: exact,
            slices: sliceMap.slices
        )
        guard let anchorSlice = covered.first else {
            throw TuringStoryPlacementAdjustmentError.noCoveredSlice(
                slotID: exact.placementID
            )
        }

        let selectedSliceIDs: [String]
        if let forcedSliceIDs, !forcedSliceIDs.isEmpty {
            let requested = forcedSliceIDs.filter { id in
                sliceMap.sliceByID[id]?.representativeWallUUID == exact.wallUUID
            }
            selectedSliceIDs =
                requested.isEmpty
                ? covered.map(\.sliceID)
                : requested

            #if DEBUG
                let knownIDs = Set(covered.map(\.sliceID))
                if requested.contains(where: { !knownIDs.contains($0) }) {
                    print(
                        "[TuringPlacementAdjust] initial selected slices extend beyond exact semantic coverage slot=\(exact.placementID)"
                    )
                }
            #endif
        } else {
            selectedSliceIDs = covered.map(\.sliceID)
        }

        let startX = TuringStoryPlacementRouteMath.localX(
            worldXZ: spinWall.startXZ,
            wall: spinWall.runtimeWall
        )
        let endX = TuringStoryPlacementRouteMath.localX(
            worldXZ: spinWall.endXZ,
            wall: spinWall.runtimeWall
        )
        let routeOrder = TuringStoryPlacementRouteMath.routeOrder(
            localX: exact.localX,
            wallOrdinal: anchorSlice.wallOrdinal,
            startLocalX: startX,
            endLocalX: endX
        )

        let typedPlacement: TuringStoryRuntimePlacement
        let transform: simd_float4x4

        switch exact.propID {
        case .door:
            let placement = TuringStoryDoorBundlePlacement(
                wallID: exact.wallUUID,
                localX: exact.runtimeLocalX,
                localY: exact.runtimeLocalY,
                depthOffset: exact.depthOffset,
                width: exact.visualWidth,
                height: exact.visualHeight,
                floorWorldY: exact.floorWorldY,
                worldYawRadians: atan2(liveWall.normal.x, liveWall.normal.z)
            )
            typedPlacement = .door(placement)
            transform = try controllers.door.adjustmentWorldTransform(
                for: placement
            )

        case .window:
            let placement = TuringStoryWindowBundlePlacement(
                wallID: exact.wallUUID,
                localX: exact.runtimeLocalX,
                localY: exact.runtimeLocalY,
                depthOffset: exact.depthOffset,
                width: exact.visualWidth,
                height: exact.visualHeight,
                floorWorldY: exact.floorWorldY,
                worldYawRadians: atan2(liveWall.normal.x, liveWall.normal.z)
            )
            typedPlacement = .window(placement)
            transform = try controllers.window.adjustmentWorldTransform(
                for: placement
            )

        case .walkieShelf:
            let placement = TuringStoryWallBundlePlacement(
                wallID: exact.wallUUID,
                localX: exact.runtimeLocalX,
                localY: exact.runtimeLocalY,
                depthOffset: exact.depthOffset,
                width: exact.visualWidth,
                height: exact.visualHeight,
                floorWorldY: exact.floorWorldY
            )
            typedPlacement = .walkieShelf(placement)
            transform = try controllers.walkie.adjustmentWorldTransform(
                for: placement
            )

        case .poster:
            let placement = WallPosterPlacement(
                wallID: exact.wallUUID,
                localX: exact.runtimeLocalX,
                localY: exact.runtimeLocalY,
                depthOffset: exact.depthOffset,
                width: exact.visualWidth,
                height: exact.visualHeight
            )
            typedPlacement = .poster(placement)
            transform = try controllers.poster.adjustmentWorldTransform(
                for: placement
            )
        }

        return TuringStoryRuntimeSlot(
            slotID: exact.placementID,
            propID: exact.propID,
            wallID: exact.wallUUID,
            wallOrdinal: spinWall.wallOrdinal,
            sliceIDs: selectedSliceIDs,
            routeOrder: routeOrder,
            worldTransform: transform,
            semanticReservation: exact.runtimeSemanticRect.wallLocalRect,
            score: exact.deterministicQuality,
            placement: typedPlacement
        )
    }
}
