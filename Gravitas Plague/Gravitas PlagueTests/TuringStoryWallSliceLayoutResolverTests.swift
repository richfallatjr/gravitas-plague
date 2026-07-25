import XCTest
@testable import Gravitas_Plague

final class TuringStoryWallSliceLayoutResolverTests: XCTestCase {
    func testDeterministicFallbackDistributesFivePropsAcrossFourteenWalls()
        throws
    {
        let fixture = makeDistributedFallbackFixture(
            wallCount: 14,
            strongestDoorWallOrdinal: 8,
            includeExactPlacements: true
        )

        let plan = try TuringStoryDeterministicWallSliceFallback().plan(
            map: fixture.map,
            catalog: fixture.catalog
        )
        let selectedWallOrdinals = try [plan.d, plan.b, plan.w, plan.s, plan.p].map { selection in
            let ids = try XCTUnwrap(selection)
            let id = try XCTUnwrap(ids.first)
            return try XCTUnwrap(Int(id)) / 10
        }

        XCTAssertEqual(selectedWallOrdinals, [8, 11, 14, 2, 5])
        XCTAssertEqual(Set(selectedWallOrdinals).count, 5)
    }

    func testDeterministicFallbackStillReturnsEveryPropWithoutExactCatalog()
        throws
    {
        let fixture = makeDistributedFallbackFixture(
            wallCount: 4,
            strongestDoorWallOrdinal: 1,
            includeExactPlacements: false
        )

        let resolved = try TuringStoryDeterministicWallSliceFallback().resolve(
            map: fixture.map,
            catalog: fixture.catalog
        )

        XCTAssertEqual(
            resolved.assignments.map(\.propID),
            [.door, .rollingBench, .window, .walkieShelf, .poster]
        )
        XCTAssertEqual(
            Set(resolved.assignments.map { $0.placement.wallUUID }).count,
            4
        )
    }

    func testNonnumericUnknownSliceIsRejectedForDeterministicFallback() throws {
        let fixture = try makeSliceFixture()
        let plan = TuringStoryWallSlicePlan(
            d: ["missing"],
            w: ["12"],
            s: ["13"],
            p: nil
        )

        XCTAssertThrowsError(
            try TuringStoryWallSliceLayoutResolver().resolve(
                plan: plan,
                map: fixture.map,
                catalog: fixture.catalog
            )
        )
    }

    func testUnknownNumericSliceProjectsToNearestKnownSliceOnRequestedWall()
        throws
    {
        let fixture = try makeSliceFixture()
        let known = try XCTUnwrap(fixture.map.slices.last)
        let requested = String(known.wallOrdinal * 10 + 9)
        let plan = TuringStoryWallSlicePlan(
            d: [requested],
            w: nil,
            s: nil,
            p: nil
        )

        let result = try TuringStoryWallSliceLayoutResolver().resolve(
            plan: plan,
            map: fixture.map,
            catalog: fixture.catalog
        )

        XCTAssertEqual(result.assignments.count, 1)
        XCTAssertEqual(result.assignments[0].propID, .door)
        XCTAssertEqual(
            result.assignments[0].sliceIDs,
            [known.sliceID]
        )
    }

    func testValidSlicesResolveWithoutChoosingReplacementSlices() throws {
        let fixture = try makeSliceFixture()
        let plan = TuringStoryWallSlicePlan(
            d: ["10"],
            w: ["12"],
            s: ["13"],
            p: nil
        )
        let result = try TuringStoryWallSliceLayoutResolver().resolve(
            plan: plan,
            map: fixture.map,
            catalog: fixture.catalog
        )

        XCTAssertEqual(result.assignments.map(\.propID), [.door, .window, .walkieShelf])
        XCTAssertEqual(result.assignments[0].sliceIDs, ["10"])
    }

    func testKnownSliceWithoutMatchingOptionStillProjectsRequestedProp() throws {
        let fixture = try makeSliceFixture()
        let selectedSlice = try XCTUnwrap(
            fixture.map.slices.first {
                !$0.options.contains(.shelfOne)
            }
        )
        let plan = TuringStoryWallSlicePlan(
            d: nil,
            w: nil,
            s: [selectedSlice.sliceID],
            p: nil
        )

        let result = try TuringStoryWallSliceLayoutResolver().resolve(
            plan: plan,
            map: fixture.map,
            catalog: fixture.catalog
        )

        XCTAssertEqual(result.assignments.count, 1)
        XCTAssertEqual(result.assignments[0].propID, .walkieShelf)
        XCTAssertEqual(result.assignments[0].sliceIDs, [selectedSlice.sliceID])
        XCTAssertEqual(
            result.assignments[0].placement.placementID,
            "s:slice-\(selectedSlice.sliceID):direct"
        )
    }

    func testEveryMappedSliceCanProjectEveryPropForManualAdjustment() {
        let fixture = makeDistributedFallbackFixture(
            wallCount: 3,
            strongestDoorWallOrdinal: 1,
            includeExactPlacements: false
        )
        let projected = TuringStoryManualPlacementProjectionBuilder().build(
            map: fixture.map
        )

        for propID in TuringStoryPropID.allCases {
            let propPlacements = projected.filter {
                $0.placement.propID == propID
            }

            XCTAssertEqual(propPlacements.count, fixture.map.slices.count)
            XCTAssertEqual(
                Set(propPlacements.map(\.placement.wallUUID)),
                Set(fixture.map.slices.map(\.representativeWallUUID))
            )
            XCTAssertEqual(
                Set(propPlacements.map(\.sliceID)),
                Set(fixture.map.slices.map(\.sliceID))
            )
            XCTAssertTrue(
                propPlacements.allSatisfy {
                    $0.placement.placementID.hasPrefix(
                        "\(propID.shortID):slice-"
                    )
                        && $0.placement.placementID.hasSuffix(":direct")
                }
            )
        }

        XCTAssertEqual(
            projected.count,
            fixture.map.slices.count * TuringStoryPropID.allCases.count
        )
    }

    private func makeDistributedFallbackFixture(
        wallCount: Int,
        strongestDoorWallOrdinal: Int,
        includeExactPlacements: Bool
    ) -> (
        map: TuringStoryWallSliceMap,
        catalog: TuringStoryExactPlacementCatalog
    ) {
        var walls: [TuringStorySpinOrderedWall] = []
        var slices: [TuringStoryWallSlice] = []
        var placements: [TuringStoryExactPlacement] = []

        for ordinal in 1...wallCount {
            let wallUUID = UUID()
            let source = TuringStoryPlacementTestSupport.wallCandidate(
                id: wallUUID,
                center: SIMD3<Float>(Float(ordinal), 1.3, 0),
                width: 2,
                height: 2.6,
                stability: 0.9
            )
            let canonical = TuringStoryPlacementTestSupport.canonicalWall(
                source: source
            )
            walls.append(
                TuringStorySpinOrderedWall(
                    wallOrdinal: ordinal,
                    publicWallID: "wall-\(ordinal)",
                    sourceWallID: "source-\(ordinal)",
                    representativeWallUUID: wallUUID,
                    startXZ: SIMD2<Float>(-1, Float(ordinal)),
                    endXZ: SIMD2<Float>(1, Float(ordinal)),
                    widthMeters: 2,
                    heightMeters: 2.6,
                    stability: 0.9,
                    sourceCandidateCount: 1,
                    aggregateFloorFrontageScore: 0.8,
                    runtimeWall: canonical
                )
            )
            slices.append(
                TuringStoryWallSlice(
                    sliceID: String(ordinal * 10),
                    numericSliceID: ordinal * 10,
                    wallOrdinal: ordinal,
                    wallID: "wall-\(ordinal)",
                    sourceWallID: "source-\(ordinal)",
                    representativeWallUUID: wallUUID,
                    localSliceIndex: 0,
                    sliceCountOnWall: 1,
                    localMinX: -1,
                    localMaxX: 1,
                    localCenterX: 0,
                    widthMeters: 2,
                    isWallStartEdge: true,
                    isWallEndEdge: true,
                    floorSupportScore: 0.8,
                    floorEvidenceKnown: true,
                    wallCenterScore: 1,
                    cornerClearanceScore: 0.8,
                    wallStability: 0.9,
                    options: Set(TuringStoryWallSliceOption.allCases)
                )
            )

            guard includeExactPlacements else { continue }
            for propID in TuringStoryPropID.allCases {
                let quality: Float =
                    propID == .door && ordinal == strongestDoorWallOrdinal
                    ? 1
                    : 0.5
                placements.append(
                    TuringStoryPlacementTestSupport.exactPlacement(
                        id: "\(propID.shortID)-\(ordinal)",
                        propID: propID,
                        wallID: "wall-\(ordinal)",
                        wallUUID: wallUUID,
                        localX: 0,
                        quality: quality
                    )
                )
            }
        }

        return (
            TuringStoryWallSliceMap(
                perimeter: TuringStorySpinOrderedPerimeter(
                    scanID: "fallback-test",
                    spinDirection: .clockwise,
                    startYawRadians: 0,
                    roomCenterXZ: .zero,
                    floorWorldY: 0,
                    isClosed: true,
                    walls: walls
                ),
                slices: slices
            ),
            TuringStoryPlacementTestSupport.catalog(placements)
        )
    }
}
