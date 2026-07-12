import XCTest
@testable import Gravitas_Plague

final class TuringStoryWallSliceLayoutResolverTests: XCTestCase {
    func testUnknownSliceRequiresPromptRepair() throws {
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
}
