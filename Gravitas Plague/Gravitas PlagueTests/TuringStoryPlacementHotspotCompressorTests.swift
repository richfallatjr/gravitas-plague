import XCTest
@testable import Gravitas_Plague

final class TuringStoryPlacementHotspotCompressorTests: XCTestCase {
    func testIllegalHorizontalHoleIsNotBridged() throws {
        let wallID = UUID()
        let placements = [-0.5, -0.4, 0.4, 0.5].enumerated().map { index, x in
            TuringStoryPlacementTestSupport.exactPlacement(
                id: "d\(index)",
                propID: .door,
                wallID: "w0",
                wallUUID: wallID,
                localX: Float(x)
            )
        }
        let atlas = try TuringStoryPlacementHotspotCompressor().compress(
            catalog: TuringStoryPlacementTestSupport.catalog(placements),
            perimeter: TuringStoryPlacementTestSupport.perimeter(wallUUID: wallID)
        )
        let doorHotspots = atlas.hotspots(for: .door)

        XCTAssertEqual(doorHotspots.count, 2)
        XCTAssertLessThan(doorHotspots[0].maximumLocalX, doorHotspots[1].minimumLocalX)
        XCTAssertEqual(Set(doorHotspots.flatMap(\.exactPlacementIDs)), Set(placements.map(\.placementID)))
    }
}
