import Foundation

struct TuringStoryDeterministicWallSliceFallback: Sendable {
    private let propOrder = TuringStoryPropID.allCases.sorted {
        $0.priority < $1.priority
    }

    func resolve(
        map: TuringStoryWallSliceMap,
        catalog: TuringStoryExactPlacementCatalog
    ) throws -> TuringStoryResolvedSliceLayout {
        let fallbackPlan = try plan(map: map, catalog: catalog)
        return try TuringStoryWallSliceLayoutResolver().resolve(
            plan: fallbackPlan,
            map: map,
            catalog: catalog,
            fallbackUsed: true
        )
    }

    func plan(
        map: TuringStoryWallSliceMap,
        catalog: TuringStoryExactPlacementCatalog
    ) throws -> TuringStoryWallSlicePlan {
        let walls = map.perimeter.walls
        guard walls.isEmpty == false else {
            throw TuringStoryWallSliceError.noWalls
        }
        guard map.slices.isEmpty == false else {
            throw TuringStoryWallSliceError.noSlices
        }

        let largestWallArea = walls
            .map { max(0.001, $0.widthMeters * $0.heightMeters) }
            .max() ?? 1
        var usedWallIDs = Set<UUID>()
        var usedSliceIDs = Set<String>()
        var selectedSliceByProp: [TuringStoryPropID: String] = [:]
        var anchorWallIndex: Int?

        for (propOffset, propID) in propOrder.enumerated() {
            let targetWallIndex: Int
            if let anchorWallIndex {
                let distributedOffset = Int(
                    (Double(propOffset) * Double(walls.count)
                        / Double(propOrder.count)).rounded()
                )
                targetWallIndex = positiveModulo(
                    anchorWallIndex + distributedOffset,
                    walls.count
                )
            } else {
                targetWallIndex = 0
            }

            let wallIndex = selectWallIndex(
                propID: propID,
                targetWallIndex: targetWallIndex,
                useGlobalBest: anchorWallIndex == nil,
                walls: walls,
                slices: map.slices,
                catalog: catalog,
                usedWallIDs: usedWallIDs,
                largestWallArea: largestWallArea
            )
            let wall = walls[wallIndex]
            let slice = selectSlice(
                propID: propID,
                wall: wall,
                slices: map.slices,
                catalog: catalog,
                usedSliceIDs: usedSliceIDs
            )

            if anchorWallIndex == nil {
                anchorWallIndex = wallIndex
            }
            usedWallIDs.insert(wall.representativeWallUUID)
            usedSliceIDs.insert(slice.sliceID)
            selectedSliceByProp[propID] = slice.sliceID

            print(
                """
                [TuringWallFallback] selected
                  prop: \(propID.rawValue)
                  targetWallOrdinal: \(walls[targetWallIndex].wallOrdinal)
                  selectedWallOrdinal: \(wall.wallOrdinal)
                  selectedSliceID: \(slice.sliceID)
                  wallDistanceFromTarget: \(circularDistance(wallIndex, targetWallIndex, walls.count))
                  candidateScore: \(String(format: "%.3f", sliceScore(propID: propID, slice: slice, catalog: catalog)))
                """
            )
        }

        let plan = TuringStoryWallSlicePlan(
            d: selectedSliceByProp[.door].map { [$0] },
            w: selectedSliceByProp[.window].map { [$0] },
            s: selectedSliceByProp[.walkieShelf].map { [$0] },
            p: selectedSliceByProp[.poster].map { [$0] }
        )
        print(
            """
            [TuringWallFallback] deterministic plan ready
              wallCount: \(walls.count)
              propCount: \(propOrder.count)
              distributionStep: \(String(format: "%.3f", Double(walls.count) / Double(propOrder.count)))
              selectedWallCount: \(usedWallIDs.count)
              selectedSlices: \(propOrder.compactMap { selectedSliceByProp[$0] })
              foundationRetryUsed: false
            """
        )
        return plan
    }

    private func selectWallIndex(
        propID: TuringStoryPropID,
        targetWallIndex: Int,
        useGlobalBest: Bool,
        walls: [TuringStorySpinOrderedWall],
        slices: [TuringStoryWallSlice],
        catalog: TuringStoryExactPlacementCatalog,
        usedWallIDs: Set<UUID>,
        largestWallArea: Float
    ) -> Int {
        let allIndices = Array(walls.indices)
        let unusedIndices = allIndices.filter {
            usedWallIDs.contains(walls[$0].representativeWallUUID) == false
        }
        let distinctPool = unusedIndices.isEmpty ? allIndices : unusedIndices
        let exactPool = distinctPool.filter {
            hasExactCandidate(
                propID: propID,
                wallID: walls[$0].representativeWallUUID,
                catalog: catalog
            )
        }
        let candidatePool = exactPool.isEmpty ? distinctPool : exactPool

        if useGlobalBest {
            return candidatePool.max {
                wallScore(
                    propID: propID,
                    wall: walls[$0],
                    slices: slices,
                    catalog: catalog,
                    largestWallArea: largestWallArea
                ) < wallScore(
                    propID: propID,
                    wall: walls[$1],
                    slices: slices,
                    catalog: catalog,
                    largestWallArea: largestWallArea
                )
            } ?? targetWallIndex
        }

        let nearestDistance = candidatePool.map {
            circularDistance($0, targetWallIndex, walls.count)
        }.min() ?? 0
        let nearest = candidatePool.filter {
            circularDistance($0, targetWallIndex, walls.count) == nearestDistance
        }
        return nearest.max {
            wallScore(
                propID: propID,
                wall: walls[$0],
                slices: slices,
                catalog: catalog,
                largestWallArea: largestWallArea
            ) < wallScore(
                propID: propID,
                wall: walls[$1],
                slices: slices,
                catalog: catalog,
                largestWallArea: largestWallArea
            )
        } ?? candidatePool[0]
    }

    private func selectSlice(
        propID: TuringStoryPropID,
        wall: TuringStorySpinOrderedWall,
        slices: [TuringStoryWallSlice],
        catalog: TuringStoryExactPlacementCatalog,
        usedSliceIDs: Set<String>
    ) -> TuringStoryWallSlice {
        let wallSlices = slices.filter {
            $0.representativeWallUUID == wall.representativeWallUUID
        }
        let unused = wallSlices.filter { usedSliceIDs.contains($0.sliceID) == false }
        let pool = unused.isEmpty ? wallSlices : unused

        return pool.max {
            let lhs = sliceScore(propID: propID, slice: $0, catalog: catalog)
            let rhs = sliceScore(propID: propID, slice: $1, catalog: catalog)
            if abs(lhs - rhs) > 0.000_001 {
                return lhs < rhs
            }
            if abs($0.localCenterX) != abs($1.localCenterX) {
                return abs($0.localCenterX) > abs($1.localCenterX)
            }
            return $0.numericSliceID > $1.numericSliceID
        } ?? mapFallbackSlice(slices)
    }

    private func mapFallbackSlice(
        _ slices: [TuringStoryWallSlice]
    ) -> TuringStoryWallSlice {
        precondition(slices.isEmpty == false)
        return slices[0]
    }

    private func wallScore(
        propID: TuringStoryPropID,
        wall: TuringStorySpinOrderedWall,
        slices: [TuringStoryWallSlice],
        catalog: TuringStoryExactPlacementCatalog,
        largestWallArea: Float
    ) -> Float {
        let bestSliceScore = slices
            .filter { $0.representativeWallUUID == wall.representativeWallUUID }
            .map { sliceScore(propID: propID, slice: $0, catalog: catalog) }
            .max() ?? 0
        let normalizedArea = max(0, wall.widthMeters * wall.heightMeters)
            / max(0.001, largestWallArea)
        return bestSliceScore * 0.80 + normalizedArea * 0.20
    }

    private func sliceScore(
        propID: TuringStoryPropID,
        slice: TuringStoryWallSlice,
        catalog: TuringStoryExactPlacementCatalog
    ) -> Float {
        let exactScore = catalog.placements(for: propID)
            .filter {
                $0.wallUUID == slice.representativeWallUUID
                    && $0.localX >= slice.localMinX - 0.001
                    && $0.localX <= slice.localMaxX + 0.001
            }
            .map(\.deterministicQuality)
            .max()
        if let exactScore {
            return 1 + exactScore
        }

        switch propID {
        case .door:
            return slice.floorSupportScore * 0.42
                + slice.wallCenterScore * 0.23
                + slice.cornerClearanceScore * 0.17
                + slice.wallStability * 0.18
        case .window:
            return slice.floorSupportScore * 0.18
                + slice.wallCenterScore * 0.32
                + slice.cornerClearanceScore * 0.24
                + slice.wallStability * 0.26
        case .walkieShelf:
            return slice.floorSupportScore * 0.16
                + slice.wallCenterScore * 0.34
                + slice.cornerClearanceScore * 0.24
                + slice.wallStability * 0.26
        case .poster:
            return slice.wallCenterScore * 0.40
                + slice.cornerClearanceScore * 0.28
                + slice.wallStability * 0.32
        }
    }

    private func hasExactCandidate(
        propID: TuringStoryPropID,
        wallID: UUID,
        catalog: TuringStoryExactPlacementCatalog
    ) -> Bool {
        catalog.placements(for: propID).contains { $0.wallUUID == wallID }
    }

    private func circularDistance(
        _ lhs: Int,
        _ rhs: Int,
        _ count: Int
    ) -> Int {
        let direct = abs(lhs - rhs)
        return min(direct, count - direct)
    }

    private func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let remainder = value % modulus
        return remainder < 0 ? remainder + modulus : remainder
    }
}
