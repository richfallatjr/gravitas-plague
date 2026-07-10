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
}
