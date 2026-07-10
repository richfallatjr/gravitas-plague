import XCTest
@testable import Gravitas_Plague

final class TuringStoryHotspotLayoutValidatorTests: XCTestCase {
    func testJointResolutionAvoidsOverlapInsideSelectedHotspots() throws {
        let wallID = UUID()
        let placements = [
            TuringStoryPlacementTestSupport.exactPlacement(
                id: "door-nearest",
                propID: .door,
                wallID: "w0",
                wallUUID: wallID,
                localX: -0.91,
                width: 1.3716
            ),
            TuringStoryPlacementTestSupport.exactPlacement(
                id: "door-compatible",
                propID: .door,
                wallID: "w0",
                wallUUID: wallID,
                localX: -1.4,
                width: 1.3716
            ),
            TuringStoryPlacementTestSupport.exactPlacement(
                id: "shelf-nearest",
                propID: .walkieShelf,
                wallID: "w0",
                wallUUID: wallID,
                localX: 0.06,
                width: 0.9144
            ),
            TuringStoryPlacementTestSupport.exactPlacement(
                id: "shelf-compatible",
                propID: .walkieShelf,
                wallID: "w0",
                wallUUID: wallID,
                localX: 0.85,
                width: 0.9144
            )
        ]
        let door = TuringStoryPlacementHotspot(
            hotspotID: "d0",
            propID: .door,
            wallID: "w0",
            wallUUID: wallID,
            minimumLocalX: -1.4,
            maximumLocalX: -0.2,
            recommendedLocalX: -0.2,
            exactPlacementIDs: ["door-nearest", "door-compatible"],
            bestFloorFrontageScore: 1,
            meanFloorFrontageScore: 1,
            floorEvidenceKnown: true,
            bestWallCenterScore: 1,
            bestCornerClearanceScore: 1,
            wallStabilityScore: 1,
            deterministicQuality: 1
        )
        let shelf = TuringStoryPlacementHotspot(
            hotspotID: "s0",
            propID: .walkieShelf,
            wallID: "w0",
            wallUUID: wallID,
            minimumLocalX: -0.35,
            maximumLocalX: 0.85,
            recommendedLocalX: 0,
            exactPlacementIDs: ["shelf-nearest", "shelf-compatible"],
            bestFloorFrontageScore: 1,
            meanFloorFrontageScore: 1,
            floorEvidenceKnown: true,
            bestWallCenterScore: 1,
            bestCornerClearanceScore: 1,
            wallStabilityScore: 1,
            deterministicQuality: 1
        )
        let atlas = TuringStoryHotspotAtlas(
            hotspots: [door, shelf],
            hotspotByID: ["d0": door, "s0": shelf],
            unavoidableConflicts: []
        )
        let context = TuringStoryHotspotPlanningContext(
            perimeter: TuringStoryPlacementTestSupport.perimeter(wallUUID: wallID),
            catalog: TuringStoryPlacementTestSupport.catalog(placements),
            feasibility: TuringStoryFeasibilityVector(door: 1, window: 0, walkieShelf: 1, poster: 0),
            posterSize: SIMD2<Float>(0.7, 0.9)
        )
        let plan = TuringStoryHotspotPlan(
            v: 1,
            scan: "scan-test",
            a: .init(
                d: .init(hotspotID: "d0", normalizedPosition: 0.42),
                w: nil,
                s: .init(hotspotID: "s0", normalizedPosition: 0.35),
                p: nil
            )
        )

        let result = try TuringStoryHotspotLayoutValidator().validate(
            plan: plan,
            context: context,
            atlas: atlas,
            liveWalls: [wallID: TuringStoryPlacementTestSupport.wallCandidate(id: wallID)]
        )

        XCTAssertEqual(result.assignments.count, 2)
        XCTAssertFalse(
            result.assignments[0].placement.semanticRect.overlaps(
                result.assignments[1].placement.semanticRect
            )
        )
    }

    func testNormalizedPositionOutsideUnitIntervalFailsWithoutClamping() {
        let wallID = UUID()
        let exact = TuringStoryPlacementTestSupport.exactPlacement(
            id: "door", propID: .door, wallID: "w0", wallUUID: wallID, localX: 0
        )
        let hotspot = TuringStoryPlacementHotspot(
            hotspotID: "d0",
            propID: .door,
            wallID: "w0",
            wallUUID: wallID,
            minimumLocalX: -0.5,
            maximumLocalX: 0.5,
            recommendedLocalX: 0,
            exactPlacementIDs: [exact.placementID],
            bestFloorFrontageScore: 1,
            meanFloorFrontageScore: 1,
            floorEvidenceKnown: true,
            bestWallCenterScore: 1,
            bestCornerClearanceScore: 1,
            wallStabilityScore: 1,
            deterministicQuality: 1
        )
        let atlas = TuringStoryHotspotAtlas(
            hotspots: [hotspot],
            hotspotByID: [hotspot.hotspotID: hotspot],
            unavoidableConflicts: []
        )
        let context = TuringStoryHotspotPlanningContext(
            perimeter: TuringStoryPlacementTestSupport.perimeter(wallUUID: wallID),
            catalog: TuringStoryPlacementTestSupport.catalog([exact]),
            feasibility: TuringStoryFeasibilityVector(door: 1, window: 0, walkieShelf: 0, poster: 0),
            posterSize: SIMD2<Float>(0.7, 0.9)
        )
        let plan = TuringStoryHotspotPlan(
            v: 1,
            scan: "scan-test",
            a: TuringStoryHotspotPlan.Assignments(
                d: TuringHotspotSelection(hotspotID: "d0", normalizedPosition: 1.01),
                w: nil,
                s: nil,
                p: nil
            )
        )

        XCTAssertThrowsError(
            try TuringStoryHotspotLayoutValidator().validate(
                plan: plan,
                context: context,
                atlas: atlas,
                liveWalls: [wallID: TuringStoryPlacementTestSupport.wallCandidate(id: wallID)]
            )
        )
    }
}
