import Foundation
import XCTest
@testable import Gravitas_Plague

final class TuringStoryWallSliceBuilderTests: XCTestCase {
    func testNumericIDsAndEqualWidthsCoverWall() throws {
        let fixture = try makeSliceFixture()
        let slices = fixture.map.slices

        XCTAssertEqual(slices.map(\.sliceID), ["10", "11", "12", "13"])
        XCTAssertEqual(slices.map(\.widthMeters).reduce(0, +), 3.66, accuracy: 0.001)
        XCTAssertLessThanOrEqual(slices.count, 10)
        XCTAssertFalse(slices.last!.options.contains(.doorTwo))
    }

    func testPromptDatasetSerializesOnlySliceIDAndOptions() throws {
        let fixture = try makeSliceFixture()
        let dataset = TuringStoryWallSlicePromptDataset.make(from: fixture.map)

        XCTAssertTrue(dataset.slices.allSatisfy { $0.count == 2 })
        XCTAssertEqual(
            dataset.slices[0],
            [
                .string(fixture.map.slices[0].sliceID),
                .string(fixture.map.slices[0].optionString)
            ]
        )

        let data = try JSONEncoder().encode(dataset)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), Set(["slices"]))
    }
}

func makeSliceFixture() throws -> (
    map: TuringStoryWallSliceMap,
    catalog: TuringStoryExactPlacementCatalog
) {
    let wallID = UUID()
    let perimeter = TuringStoryPlacementTestSupport.perimeter(
        wallUUID: wallID,
        width: 3.66
    )
    let spinPerimeter = try TuringStorySpinOrderedPerimeterBuilder().build(
        perimeter: perimeter,
        spin: TuringStoryScanSpinResult(
            startYawRadians: 0,
            accumulatedYawRadians: -2 * .pi,
            direction: .clockwise
        )
    )
    let placements = [
        TuringStoryPlacementTestSupport.exactPlacement(
            id: "door", propID: .door, wallID: "w0", wallUUID: wallID, localX: -0.5
        ),
        TuringStoryPlacementTestSupport.exactPlacement(
            id: "window", propID: .window, wallID: "w0", wallUUID: wallID, localX: 0.5
        ),
        TuringStoryPlacementTestSupport.exactPlacement(
            id: "shelf", propID: .walkieShelf, wallID: "w0", wallUUID: wallID, localX: 1.3
        ),
        TuringStoryPlacementTestSupport.exactPlacement(
            id: "poster", propID: .poster, wallID: "w0", wallUUID: wallID, localX: -1.3
        )
    ]
    let catalog = TuringStoryPlacementTestSupport.catalog(placements)
    return (
        try TuringStoryWallSliceBuilder().build(
            perimeter: spinPerimeter,
            catalog: catalog
        ),
        catalog
    )
}
