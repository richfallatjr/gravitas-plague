import XCTest
import simd

@testable import Gravitas_Plague

final class TuringStoryPlacementCandidateCacheTests: XCTestCase {
    func testAssemblerRetainsEveryCatalogCandidate() throws {
        let wall = UUID()
        let slots = [
            TuringStoryPlacementTestFactory.slot(
                id: "p:1",
                propID: .poster,
                wallID: wall,
                wallOrdinal: 1,
                routeOrder: 1.20
            ),
            TuringStoryPlacementTestFactory.slot(
                id: "p:2",
                propID: .poster,
                wallID: wall,
                wallOrdinal: 1,
                routeOrder: 1.10
            ),
            TuringStoryPlacementTestFactory.slot(
                id: "p:3",
                propID: .poster,
                wallID: wall,
                wallOrdinal: 1,
                routeOrder: 1.30
            ),
        ]

        let seed = try TuringStoryPlacementCandidateCacheAssembler().assemble(
            scanID: "S",
            catalogSlotsByProp: [.poster: slots],
            resolvedInitialSlotsByProp: [.poster: slots[0]]
        )

        XCTAssertEqual(seed.candidatesByProp[.poster]?.count, 3)
        XCTAssertEqual(
            seed.candidatesByProp[.poster]?.map(\.slotID),
            ["p:2", "p:1", "p:3"]
        )
    }

    func testCoveredSlicesUseCanonicalSemanticRect() {
        let wall = UUID()
        let exact = makeExactPlacement(
            wallID: wall,
            semanticMinX: -0.30,
            semanticMaxX: 0.60
        )
        let slices = [
            makeSlice(id: "10", wallID: wall, index: 0, minX: -1.0, maxX: -0.5),
            makeSlice(id: "11", wallID: wall, index: 1, minX: -0.5, maxX: 0.0),
            makeSlice(id: "12", wallID: wall, index: 2, minX: 0.0, maxX: 0.5),
            makeSlice(id: "13", wallID: wall, index: 3, minX: 0.5, maxX: 1.0),
        ]

        XCTAssertEqual(
            TuringStoryPlacementRouteMath.coveredSlices(
                exact: exact,
                slices: slices
            ).map(\.sliceID),
            ["11", "12", "13"]
        )
    }

    func testRouteOrderFollowsClockwiseWallDirection() {
        XCTAssertEqual(
            TuringStoryPlacementRouteMath.routeOrder(
                localX: -1,
                wallOrdinal: 2,
                startLocalX: -1,
                endLocalX: 1
            ),
            2.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TuringStoryPlacementRouteMath.routeOrder(
                localX: 0,
                wallOrdinal: 2,
                startLocalX: -1,
                endLocalX: 1
            ),
            2.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TuringStoryPlacementRouteMath.routeOrder(
                localX: 1,
                wallOrdinal: 2,
                startLocalX: -1,
                endLocalX: 1
            ),
            3.0,
            accuracy: 0.0001
        )
    }

    func testRouteOrderFollowsCounterclockwiseWallDirection() {
        XCTAssertEqual(
            TuringStoryPlacementRouteMath.routeOrder(
                localX: 1,
                wallOrdinal: 2,
                startLocalX: 1,
                endLocalX: -1
            ),
            2.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TuringStoryPlacementRouteMath.routeOrder(
                localX: 0,
                wallOrdinal: 2,
                startLocalX: 1,
                endLocalX: -1
            ),
            2.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TuringStoryPlacementRouteMath.routeOrder(
                localX: -1,
                wallOrdinal: 2,
                startLocalX: 1,
                endLocalX: -1
            ),
            3.0,
            accuracy: 0.0001
        )
    }

    func testAssemblerInsertsInitialDirectProjectionWhenAbsent() throws {
        let wall = UUID()
        let catalog = TuringStoryPlacementTestFactory.slot(
            id: "p:catalog",
            propID: .poster,
            wallID: wall,
            wallOrdinal: 1,
            routeOrder: 1.2
        )
        let direct = TuringStoryPlacementTestFactory.slot(
            id: "p:slice-11:direct",
            propID: .poster,
            wallID: wall,
            wallOrdinal: 1,
            routeOrder: 1.5
        )

        let seed = try TuringStoryPlacementCandidateCacheAssembler().assemble(
            scanID: "S",
            catalogSlotsByProp: [.poster: [catalog]],
            resolvedInitialSlotsByProp: [.poster: direct]
        )

        XCTAssertEqual(seed.candidatesByProp[.poster]?.count, 2)
        XCTAssertTrue(
            seed.candidatesByProp[.poster]?.contains(where: {
                $0.slotID == direct.slotID
            }) == true
        )
        XCTAssertEqual(
            seed.initiallySelectedSlotIDByProp[.poster],
            direct.slotID
        )
    }

    func testCircularRouteWrapsFinalToFirstAndFirstToFinal() {
        XCTAssertEqual(
            TuringStoryPlacementRouteMath.wrappedIndex(
                current: 3,
                direction: 1,
                count: 4
            ),
            0
        )
        XCTAssertEqual(
            TuringStoryPlacementRouteMath.wrappedIndex(
                current: 0,
                direction: -1,
                count: 4
            ),
            3
        )
    }

    private func makeExactPlacement(
        wallID: UUID,
        semanticMinX: Float,
        semanticMaxX: Float
    ) -> TuringStoryExactPlacement {
        TuringStoryExactPlacement(
            placementID: "p:test",
            propID: .poster,
            wallUUID: wallID,
            wallID: "wall-1",
            localX: (semanticMinX + semanticMaxX) * 0.5,
            localY: 0,
            worldBottomY: 1,
            worldTopY: 2,
            reservationWidth: semanticMaxX - semanticMinX,
            reservationHeight: 1,
            visualWidth: 0.5,
            visualHeight: 0.8,
            depthOffset: 0.018,
            floorWorldY: 0,
            floorFrontageScore: 1,
            floorEvidenceKnown: true,
            wallCenterScore: 1,
            cornerClearanceScore: 1,
            wallStabilityScore: 1,
            deterministicQuality: 1,
            semanticRect: TuringStorySemanticRect(
                minX: semanticMinX,
                minY: -0.5,
                maxX: semanticMaxX,
                maxY: 0.5
            ),
            runtimeLocalX: 0,
            runtimeLocalY: 0,
            runtimeSemanticRect: TuringStorySemanticRect(
                minX: 100,
                minY: 100,
                maxX: 101,
                maxY: 101
            ),
            liveWallCenterSnapshot: .zero,
            liveWallNormalSnapshot: SIMD3<Float>(0, 0, 1)
        )
    }

    private func makeSlice(
        id: String,
        wallID: UUID,
        index: Int,
        minX: Float,
        maxX: Float
    ) -> TuringStoryWallSlice {
        TuringStoryWallSlice(
            sliceID: id,
            numericSliceID: Int(id)!,
            wallOrdinal: 1,
            wallID: "wall-1",
            sourceWallID: "source-1",
            representativeWallUUID: wallID,
            localSliceIndex: index,
            sliceCountOnWall: 4,
            localMinX: minX,
            localMaxX: maxX,
            localCenterX: (minX + maxX) * 0.5,
            widthMeters: maxX - minX,
            isWallStartEdge: index == 0,
            isWallEndEdge: index == 3,
            floorSupportScore: 1,
            floorEvidenceKnown: true,
            wallCenterScore: 1,
            cornerClearanceScore: 1,
            wallStability: 1,
            options: [.posterOne]
        )
    }
}

