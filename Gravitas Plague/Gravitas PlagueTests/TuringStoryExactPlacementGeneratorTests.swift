import XCTest
import simd
@testable import Gravitas_Plague

final class TuringStoryExactPlacementGeneratorTests: XCTestCase {
    func testGeneratorIncludesCenterAndBothLegalExtremesAtTenCentimeterSampling() throws {
        let wallID = UUID()
        let raw = TuringStoryPlacementTestSupport.wallCandidate(
            id: wallID,
            center: SIMD3<Float>(0, 1.3, 0),
            width: 4,
            height: 2.6
        )
        let canonical = TuringStoryPlacementTestSupport.canonicalWall(source: raw)
        let floor = TuringStoryPlacementTestSupport.floorCandidate(center: SIMD3<Float>(0, 0, 2))
        let room = TuringStoryCleansedRoom(
            scanID: "scan-generator",
            viewerPosition: SIMD3<Float>(0, 1.7, 2),
            viewerForward: SIMD3<Float>(0, 0, -1),
            floor: TuringStoryCanonicalFloor(
                worldY: 0,
                totalArea: floor.area,
                confidence: 1,
                sourceFloors: [floor]
            ),
            walls: [canonical],
            rawWallByID: [wallID: raw],
            fixedOccupancy: []
        )
        let perimeter = TuringStoryPlacementTestSupport.perimeter(
            wallUUID: wallID,
            width: 4
        )

        let catalog = try TuringStoryExactPlacementGenerator().generate(
            room: room,
            perimeter: perimeter,
            frontageEvaluator: TuringStoryFloorFrontageEvaluator()
        )
        let doorX = catalog.placements(for: .door).map(\.localX).sorted()

        XCTAssertTrue(doorX.contains(0))
        XCTAssertGreaterThan(doorX.count, 3)
        XCTAssertEqual(doorX.first!, -doorX.last!, accuracy: 0.011)
        for pair in zip(doorX, doorX.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.1 - pair.0, 0.101)
        }
    }
}
