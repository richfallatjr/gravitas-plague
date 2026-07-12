import XCTest
import simd
@testable import Gravitas_Plague

final class TuringStorySpinOrderedPerimeterBuilderTests: XCTestCase {
    func testOrderStartsAtScanHeadingAndFollowsSpinDirection() throws {
        let frontID = UUID()
        let rightID = UUID()
        let frontRaw = TuringStoryPlacementTestSupport.wallCandidate(
            id: frontID,
            center: SIMD3<Float>(0, 1.3, 2)
        )
        let rightRaw = TuringStoryPlacementTestSupport.wallCandidate(
            id: rightID,
            center: SIMD3<Float>(2, 1.3, 0),
            normal: SIMD3<Float>(-1, 0, 0),
            right: SIMD3<Float>(0, 0, 1)
        )
        let perimeter = TuringStoryRoomPerimeter(
            scanID: "spin-order",
            floorWorldY: 0,
            roomCenterXZ: .zero,
            isClosed: false,
            wallsClockwise: [
                wall(id: "front", raw: frontRaw),
                wall(id: "right", raw: rightRaw)
            ],
            wallIDBySourceUUID: [frontID: "front", rightID: "right"]
        )
        let result = try TuringStorySpinOrderedPerimeterBuilder().build(
            perimeter: perimeter,
            spin: TuringStoryScanSpinResult(
                startYawRadians: -0.05,
                accumulatedYawRadians: 2 * .pi,
                direction: .counterClockwise
            )
        )

        XCTAssertEqual(result.walls.map(\.sourceWallID), ["front", "right"])
        XCTAssertEqual(result.walls.map(\.wallOrdinal), [1, 2])
    }

    func testSpinRouteRetainsAllFourteenDetectedWalls() throws {
        let perimeterWalls = (0..<14).map { index in
            let angle = Float(index) / 14 * 2 * Float.pi
            let id = UUID()
            let raw = TuringStoryPlacementTestSupport.wallCandidate(
                id: id,
                center: SIMD3<Float>(sin(angle) * 3, 1.3, cos(angle) * 3)
            )
            return wall(id: "wall-\(index)", raw: raw)
        }
        let perimeter = TuringStoryRoomPerimeter(
            scanID: "fourteen-walls",
            floorWorldY: 0,
            roomCenterXZ: .zero,
            isClosed: true,
            wallsClockwise: perimeterWalls,
            wallIDBySourceUUID: Dictionary(
                uniqueKeysWithValues: perimeterWalls.map {
                    ($0.representativeWallUUID, $0.wallID)
                }
            )
        )

        let result = try TuringStorySpinOrderedPerimeterBuilder().build(
            perimeter: perimeter,
            spin: TuringStoryScanSpinResult(
                startYawRadians: 0,
                accumulatedYawRadians: -2 * .pi,
                direction: .clockwise
            )
        )

        XCTAssertEqual(result.walls.count, 14)
        XCTAssertEqual(result.walls.map(\.wallOrdinal), Array(1...14))
    }

    private func wall(id: String, raw: WallCandidate) -> TuringStoryPerimeterWall {
        let canonical = TuringStoryPlacementTestSupport.canonicalWall(source: raw)
        let half = canonical.right * (canonical.width * 0.5)
        return TuringStoryPerimeterWall(
            wallID: id,
            representativeWallUUID: raw.id,
            startXZ: SIMD2<Float>(raw.center.x - half.x, raw.center.z - half.z),
            endXZ: SIMD2<Float>(raw.center.x + half.x, raw.center.z + half.z),
            heightMeters: raw.height,
            stability: raw.stabilityScore,
            sourceCandidateCount: 1,
            aggregateFloorFrontageScore: 1,
            runtimeWall: canonical
        )
    }
}
