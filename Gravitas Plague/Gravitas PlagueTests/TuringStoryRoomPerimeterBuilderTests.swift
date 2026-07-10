import XCTest
import simd
@testable import Gravitas_Plague

final class TuringStoryRoomPerimeterBuilderTests: XCTestCase {
    func testRectangleProducesClockwiseClosedPerimeterWithoutDroppingOldWalls() throws {
        let walls = [
            TuringStoryPlacementTestSupport.wallCandidate(
                center: SIMD3<Float>(0, 1.3, -2),
                normal: SIMD3<Float>(0, 0, 1),
                right: SIMD3<Float>(1, 0, 0)
            ),
            TuringStoryPlacementTestSupport.wallCandidate(
                center: SIMD3<Float>(2, 1.3, 0),
                normal: SIMD3<Float>(-1, 0, 0),
                right: SIMD3<Float>(0, 0, 1)
            ),
            TuringStoryPlacementTestSupport.wallCandidate(
                center: SIMD3<Float>(0, 1.3, 2),
                normal: SIMD3<Float>(0, 0, -1),
                right: SIMD3<Float>(-1, 0, 0)
            ),
            TuringStoryPlacementTestSupport.wallCandidate(
                center: SIMD3<Float>(-2, 1.3, 0),
                normal: SIMD3<Float>(1, 0, 0),
                right: SIMD3<Float>(0, 0, -1)
            )
        ]
        let floor = TuringStoryPlacementTestSupport.floorCandidate()
        let room = TuringStoryCleansedRoom(
            scanID: "scan-rectangle",
            viewerPosition: SIMD3<Float>(0, 1.7, 0),
            viewerForward: SIMD3<Float>(0, 0, -1),
            floor: TuringStoryCanonicalFloor(
                worldY: 0,
                totalArea: floor.area,
                confidence: 1,
                sourceFloors: [floor]
            ),
            walls: walls.map {
                TuringStoryPlacementTestSupport.canonicalWall(source: $0)
            },
            rawWallByID: Dictionary(uniqueKeysWithValues: walls.map { ($0.id, $0) }),
            fixedOccupancy: []
        )

        let result = try TuringStoryRoomPerimeterBuilder().build(
            room: room,
            frontageEvaluator: TuringStoryFloorFrontageEvaluator()
        )

        XCTAssertEqual(result.wallsClockwise.count, 4)
        XCTAssertTrue(result.isClosed)
        XCTAssertEqual(result.wallsClockwise.map(\.wallID), ["w0", "w1", "w2", "w3"])
    }
}
